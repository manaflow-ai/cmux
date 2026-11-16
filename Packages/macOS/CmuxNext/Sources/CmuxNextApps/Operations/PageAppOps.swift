import Foundation

/// The browser tab a `page.*` call acts on, as the app's browser glue resolves it.
public nonisolated struct PageAppTab: Sendable {
    /// The tab's id (the `tab` param a later call can name).
    public var id: String
    public var url: String
    /// The document's `scheme://host[:port]` (Page Info's key); nil for a page with none.
    public var origin: String?
    public var title: String
    /// Runs a script in the tab's isolated world as cmux (`world: .isolated, gesture: .cmux`).
    public var evaluate: @MainActor @Sendable (String) async throws -> AppJSON

    public init(id: String, url: String, origin: String?, title: String, evaluate: @escaping @MainActor @Sendable (String) async throws -> AppJSON) {
        self.id = id
        self.url = url
        self.origin = origin
        self.title = title
        self.evaluate = evaluate
    }
}

/// What `PageAppOps` asks of the browser: tabs and Page Info's JavaScript row.
public nonisolated struct PageAppHost: Sendable {
    /// The tab with this id, or with nil the selected browser tab of the key window; nil for none.
    public var tab: @MainActor @Sendable (_ id: String?) -> PageAppTab?
    /// `raw` as an origin Page Info keys permissions by, or nil when it is not an http(s) origin.
    public var origin: @MainActor @Sendable (_ raw: String) -> String?
    /// Whether `origin` may run JavaScript in the profile of `tab` (the default profile without one).
    public var javaScriptAllowed: @MainActor @Sendable (_ origin: String, _ tab: String?) -> Bool
    /// Page Info's JavaScript row: stores the choice, hands it to the engines and reloads the origin's open tabs.
    public var setJavaScript: @MainActor @Sendable (_ origin: String, _ tab: String?, _ allowed: Bool) async -> Void

    public init(tab: @escaping @MainActor @Sendable (String?) -> PageAppTab?, origin: @escaping @MainActor @Sendable (String) -> String?,
                javaScriptAllowed: @escaping @MainActor @Sendable (String, String?) -> Bool,
                setJavaScript: @escaping @MainActor @Sendable (String, String?, Bool) async -> Void) {
        self.tab = tab
        self.origin = origin
        self.javaScriptAllowed = javaScriptAllowed
        self.setJavaScript = setJavaScript
    }
}

/// The `page` family (scopes `page:read`, `site_settings:*`): `page.read` runs the daemon's own
/// reader script (`params.script`, never an extension's) in the tab's isolated world and answers
/// `{tab, url, origin, title}` merged with the script's object; `page.javascript.get` / `.set` read
/// and write Page Info's per-site JavaScript setting. Validation and scripts live in the daemon;
/// this only reaches the tab.
public nonisolated struct PageAppOps: AppHostCapabilityHandler {
    let host: PageAppHost

    public init(host: PageAppHost) {
        self.host = host
    }

    public var families: Set<String> { ["page"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        let tabID = try Self.optionalString(request.params, "tab", op: request.op)
        switch request.op {
        case "page.read":
            guard let script = request.params["script"]?.stringValue, !script.isEmpty else { throw Self.invalid("page.read needs a script") }
            let tab = try await resolve(tabID)
            let value: AppJSON
            do { value = try await tab.evaluate(script) } catch {
                throw AppHostCapabilityError(code: "operation.failed", message: "the page could not be read: \(error)", retryable: true)
            }
            guard case .object(var fields) = value else {
                throw AppHostCapabilityError(code: "operation.failed", message: "the page reader returned no object")
            }
            fields["tab"] = .string(tab.id)
            fields["url"] = .string(tab.url)
            fields["origin"] = tab.origin.map(AppJSON.string) ?? .null
            fields["title"] = .string(tab.title)
            return .object(fields)
        case "page.javascript.get":
            let origin = try await origin(request, tabID: tabID)
            return ["origin": .string(origin), "allowed": .bool(await host.javaScriptAllowed(origin, tabID))]
        case "page.javascript.set":
            guard let allowed = request.params["allowed"]?.boolValue else { throw Self.invalid("page.javascript.set needs allowed (a boolean)") }
            let origin = try await origin(request, tabID: tabID)
            await host.setJavaScript(origin, tabID, allowed)
            return ["origin": .string(origin), "allowed": .bool(allowed)]
        default:
            throw .unsupported(request.op)
        }
    }

    private func resolve(_ tabID: String?) async throws(AppHostCapabilityError) -> PageAppTab {
        guard let tab = await host.tab(tabID) else {
            throw AppHostCapabilityError(code: "page.none", message: tabID == nil ? "No browser tab is open" : "No browser tab \(tabID ?? "") is open")
        }
        return tab
    }

    /// `params.origin` (an http(s) origin), else the origin of the call's tab.
    private func origin(_ request: AppHostCapabilityRequest, tabID: String?) async throws(AppHostCapabilityError) -> String {
        if let raw = try Self.optionalString(request.params, "origin", op: request.op) {
            guard let origin = await host.origin(raw) else { throw Self.invalid("origin is an http(s) scheme://host[:port]") }
            return origin
        }
        guard let origin = try await resolve(tabID).origin, await host.origin(origin) != nil else {
            throw Self.invalid("this page is not an http(s) site")
        }
        return origin
    }

    static func optionalString(_ params: AppJSON, _ key: String, op: String) throws(AppHostCapabilityError) -> String? {
        guard let value = params[key], !value.isNull else { return nil }
        guard let string = value.stringValue, !string.isEmpty else { throw invalid("\(op) \(key) is a non-empty string") }
        return string
    }

    static func invalid(_ message: String) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "validation.invalid", message: message)
    }
}

/// One site style from the daemon's `apps-page-styles` snapshot.
public nonisolated struct PageStyleEntry: Hashable, Sendable {
    public var app: String
    public var origin: String
    public var css: String
    /// The daemon's self-contained installer: puts `css` in the document, or removes it when empty.
    public var source: String

    public init(app: String, origin: String, css: String, source: String) {
        self.app = app
        self.origin = origin
        self.css = css
        self.source = source
    }

    /// An entry with no css removes the app's style from the origin's open tabs and is not kept.
    public var isRemoval: Bool { css.isEmpty }
}

/// The latest `apps-page-styles` snapshot, in memory only (the daemon persists it).
public nonisolated struct PageStyleSnapshot: Sendable {
    public private(set) var entries: [PageStyleEntry] = []

    public init() {}

    /// Replaces the snapshot with `payload`'s `styles` (always the full set). Returns every entry,
    /// removals included, to run on open tabs of its origin now; removals are then forgotten.
    @discardableResult
    public mutating func replace(with payload: AppJSON) -> [PageStyleEntry] {
        let all = (payload["styles"]?.arrayValue ?? []).compactMap { item -> PageStyleEntry? in
            guard let app = item["app"]?.stringValue, let origin = item["origin"]?.stringValue,
                  let css = item["css"]?.stringValue, let source = item["source"]?.stringValue, !source.isEmpty else { return nil }
            return PageStyleEntry(app: app, origin: origin, css: css, source: source)
        }
        entries = all.filter { !$0.isRemoval }
        return all
    }

    /// The installers a document of `origin` runs at commit.
    public func sources(for origin: String) -> [String] {
        entries.filter { $0.origin == origin }.map(\.source)
    }
}
