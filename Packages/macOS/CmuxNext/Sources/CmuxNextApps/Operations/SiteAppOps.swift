import Foundation

/// What `SiteAppOps` asks of the browser: tabs' origins and Page Info's JavaScript row.
public nonisolated struct SiteAppHost: Sendable {
    /// The document origin of tab `id`, or with nil of the key window's selected browser tab: nil when
    /// there is no such tab, `.some(nil)` for a tab whose page has no origin.
    public var tabOrigin: @MainActor @Sendable (_ tab: String?) -> String??
    /// `raw` as an origin Page Info keys permissions by, or nil when it is not an http(s) origin.
    public var origin: @MainActor @Sendable (_ raw: String) -> String?
    /// Whether `origin` may run JavaScript in the profile of `tab` (the default profile without one).
    public var javaScriptAllowed: @MainActor @Sendable (_ origin: String, _ tab: String?) -> Bool
    /// Page Info's JavaScript row: stores the choice, hands it to the engines and reloads the origin's open tabs.
    public var setJavaScript: @MainActor @Sendable (_ origin: String, _ tab: String?, _ allowed: Bool) async -> Void

    public init(tabOrigin: @escaping @MainActor @Sendable (String?) -> String??, origin: @escaping @MainActor @Sendable (String) -> String?,
                javaScriptAllowed: @escaping @MainActor @Sendable (String, String?) -> Bool,
                setJavaScript: @escaping @MainActor @Sendable (String, String?, Bool) async -> Void) {
        self.tabOrigin = tabOrigin
        self.origin = origin
        self.javaScriptAllowed = javaScriptAllowed
        self.setJavaScript = setJavaScript
    }
}

/// The `browser.site` family the Mac app owns (scopes `site_settings:read` / `site_settings:write`):
/// `browser.site.javascript.get` / `.set` read and write Page Info's per-site JavaScript setting,
/// `{origin?, tab?}` and `{origin?, tab?, allowed}`, answering `{origin, allowed}`. The style ops of
/// the family are the daemon's; validation lives there. This only reaches the browser.
public nonisolated struct SiteAppOps: AppHostCapabilityHandler {
    let host: SiteAppHost

    public init(host: SiteAppHost) {
        self.host = host
    }

    public var families: Set<String> { ["browser.site"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        switch request.op {
        case "browser.site.javascript.get":
            let tabID = try Self.optionalString(request.params, "tab", op: request.op)
            let origin = try await origin(request, tabID: tabID)
            return ["origin": .string(origin), "allowed": .bool(await host.javaScriptAllowed(origin, tabID))]
        case "browser.site.javascript.set":
            let tabID = try Self.optionalString(request.params, "tab", op: request.op)
            guard let allowed = request.params["allowed"]?.boolValue else { throw Self.invalid("\(request.op) needs allowed (a boolean)") }
            let origin = try await origin(request, tabID: tabID)
            await host.setJavaScript(origin, tabID, allowed)
            return ["origin": .string(origin), "allowed": .bool(allowed)]
        default:
            throw .unsupported(request.op)
        }
    }

    /// `params.origin` (an http(s) origin), else the origin of the call's tab.
    private func origin(_ request: AppHostCapabilityRequest, tabID: String?) async throws(AppHostCapabilityError) -> String {
        if let raw = try Self.optionalString(request.params, "origin", op: request.op) {
            guard let origin = await host.origin(raw) else { throw Self.invalid("origin is an http(s) scheme://host[:port]") }
            return origin
        }
        guard let found = await host.tabOrigin(tabID) else {
            throw AppHostCapabilityError(code: "page.none", message: tabID.map { "No browser tab \($0) is open" } ?? "No browser tab is open")
        }
        guard let origin = found, await host.origin(origin) != nil else { throw Self.invalid("this page is not an http(s) site") }
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

/// One site style from the daemon's `apps-site-styles` snapshot.
public nonisolated struct SiteStyleEntry: Hashable, Sendable {
    public var app: String
    public var origin: String
    public var css: String
    /// The daemon's self-contained installer: puts `css` in the document (`data-cmux-site-style`), or
    /// removes it when empty.
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

/// The latest `apps-site-styles` snapshot, in memory only (the daemon persists it).
public nonisolated struct SiteStyleSnapshot: Sendable {
    public private(set) var entries: [SiteStyleEntry] = []

    public init() {}

    /// Replaces the snapshot with `payload`'s `styles` (always the full set). Returns every entry,
    /// removals included, to run on open tabs of its origin now; removals are then forgotten.
    @discardableResult
    public mutating func replace(with payload: AppJSON) -> [SiteStyleEntry] {
        let all = (payload["styles"]?.arrayValue ?? []).compactMap { item -> SiteStyleEntry? in
            guard let app = item["app"]?.stringValue, let origin = item["origin"]?.stringValue,
                  let css = item["css"]?.stringValue, let source = item["source"]?.stringValue, !source.isEmpty else { return nil }
            return SiteStyleEntry(app: app, origin: origin, css: css, source: source)
        }
        entries = all.filter { !$0.isRemoval }
        return all
    }

    /// An `apps-site-styles` payload as each origin's installers in order: `now` to run on open tabs
    /// (removals included), `kept` for later document commits (removals dropped).
    public static func installers(_ payload: AppJSON) -> (now: [String: [String]], kept: [String: [String]]) {
        var snapshot = SiteStyleSnapshot()
        let now = snapshot.replace(with: payload)
        func byOrigin(_ entries: [SiteStyleEntry]) -> [String: [String]] { Dictionary(grouping: entries, by: \.origin).mapValues { $0.map(\.source) } }
        return (byOrigin(now), byOrigin(snapshot.entries))
    }

    /// The installers a document of `origin` runs at commit.
    public func sources(for origin: String) -> [String] {
        entries.filter { $0.origin == origin }.map(\.source)
    }
}
