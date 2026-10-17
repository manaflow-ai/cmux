public import Foundation

/// An extension omnibox keyword as `cmux_shim_omnibox_keywords` reports it.
public struct CEFOmniboxKeyword: Equatable, Sendable {
    public var extensionID: String
    public var keyword: String
    public var name: String
    public var defaultDescription: String?
}

/// A suggestion row of an extension (`CMUX_SHIM_OMNIBOX_SUGGESTIONS`).
public struct CEFOmniboxSuggestion: Equatable, Sendable {
    public var content: String
    public var description: String
}

/// chrome.omnibox keyword sessions over the fork (API 12): keyword lists
/// (cached per request context until extensions change), session events,
/// and suggestions matched to their request by id, each with a deadline.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFOmniboxKeywords.swift`.
@MainActor
public final class CEFOmniboxKeywords {
    public static let minimumForkAPI: Int32 = 12
    /// Longest wait for an extension's suggestions; later rows are dropped.
    static let suggestionTimeout: Duration = .seconds(3)

    unowned let runtime: CEFRuntime
    private let replies = CEFReplyWaiters<Int32, String>()
    private var nextRequest: Int32 = 1
    private var cache: [String: [CEFOmniboxKeyword]] = [:]

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// Decodes `cmux_omnibox_keywords` JSON.
    nonisolated static func keywords(json: String) -> [CEFOmniboxKeyword] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["extension_id"] as? String, let keyword = item["keyword"] as? String,
                  !id.isEmpty, !keyword.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? keyword
            return CEFOmniboxKeyword(extensionID: id, keyword: keyword, name: name,
                                     defaultDescription: item["default_description"] as? String)
        }
    }

    /// Decodes suggestion JSON (`[{"content","description",...}]`).
    nonisolated static func suggestions(json: String) -> [CEFOmniboxSuggestion] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let content = item["content"] as? String, !content.isEmpty else { return nil }
            return CEFOmniboxSuggestion(content: content, description: item["description"] as? String ?? content)
        }
    }

    /// Keywords of `browser`'s profile; read once per profile until
    /// extensions change.
    public func keywords(browser: CEFBrowser) -> [CEFOmniboxKeyword] {
        guard let id = browser.browserID, let shim = runtime.shim,
              shim.forkAPIVersion() >= Self.minimumForkAPI else { return [] }
        let key = browser.contextKey
        if let cached = cache[key] { return cached }
        let keywords = shim.takeString(shim.omniboxKeywords(id)).map(Self.keywords(json:)) ?? []
        cache[key] = keywords
        return keywords
    }

    /// Extensions changed (installed, removed, enabled, disabled).
    func invalidate() {
        cache.removeAll()
    }

    public func started(browser: CEFBrowser, extensionID: String) {
        send(browser, extensionID, event: 0, text: "", value: 0)
    }

    /// `disposition`: 0 current tab, 1 new foreground tab, 2 new background tab.
    public func entered(browser: CEFBrowser, extensionID: String, text: String, disposition: Int32) {
        send(browser, extensionID, event: 2, text: text, value: disposition)
    }

    public func cancelled(browser: CEFBrowser, extensionID: String) {
        send(browser, extensionID, event: 3, text: "", value: 0)
    }

    /// Sends the text; returns the extension's rows, or nil when it does not
    /// listen or does not answer in time.
    public func suggestions(browser: CEFBrowser, extensionID: String, text: String) async -> [CEFOmniboxSuggestion]? {
        guard let id = browser.browserID, let shim = runtime.shim else { return nil }
        let request = nextRequest
        nextRequest &+= 1
        let json = try? await replies.send(
            timeout: Self.suggestionTimeout,
            notStarted: CEFError.browserClosed,
            timeoutError: { CEFError.timedOut("omnibox suggestions") }
        ) {
            let listens = extensionID.withCString { ext in text.withCString { shim.omniboxInput(id, ext, 1, $0, request) } }
            return listens == 1 ? request : nil
        }
        return json.map(Self.suggestions(json:))
    }

    /// CMUX_SHIM_OMNIBOX_SUGGESTIONS: resumes the request's waiter (late ones drop).
    func suggestionsArrived(requestID: Int32, json: String) {
        replies.resolve(requestID, with: .success(json))
    }

    private func send(_ browser: CEFBrowser, _ extensionID: String, event: Int32, text: String, value: Int32) {
        guard let id = browser.browserID, let shim = runtime.shim else { return }
        _ = extensionID.withCString { ext in text.withCString { shim.omniboxInput(id, ext, event, $0, value) } }
    }
}
