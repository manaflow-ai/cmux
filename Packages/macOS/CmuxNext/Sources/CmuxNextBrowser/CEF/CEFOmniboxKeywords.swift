import Foundation

/// chrome.omnibox keyword sessions over the fork (API 12): keyword lists,
/// session events, and suggestions matched to their request by id, each
/// with a deadline (architecture.md 5a).
@MainActor final class CEFOmniboxKeywords {
    /// Longest wait for an extension's suggestions; later rows are dropped.
    static let suggestionTimeout: Duration = .seconds(3)

    private let replies = CEFReplyWaiters<Int32, String>()
    private var nextRequest: Int32 = 1

    /// Decodes `cmux_omnibox_keywords` JSON.
    nonisolated static func keywords(json: String) -> [OmnibarKeyword] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["extension_id"] as? String, let keyword = item["keyword"] as? String,
                  !id.isEmpty, !keyword.isEmpty else { return nil }
            return OmnibarKeyword(extensionID: id, keyword: keyword, name: item["name"] as? String ?? keyword,
                                  defaultDescription: item["default_description"] as? String)
        }
    }

    /// Decodes suggestion JSON into rows: the default row for the typed text
    /// first (shown even before the extension answers), then the
    /// extension's rows in order.
    nonisolated static func rows(json: String, keyword: OmnibarKeyword, text: String) -> [BrowserSuggestion] {
        var rows: [BrowserSuggestion] = []
        if !text.isEmpty {
            let description = keyword.defaultDescription.map { $0.replacingOccurrences(of: "%s", with: text) }
                ?? "\(keyword.name): \(text)"
            rows.append(OmnibarKeyword.suggestionRow(extensionID: keyword.extensionID, content: text,
                                                     description: description, rank: 0))
        }
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return rows }
        for item in items {
            guard let content = item["content"] as? String, !content.isEmpty,
                  !rows.contains(where: { $0.content == content }) else { continue }
            rows.append(OmnibarKeyword.suggestionRow(extensionID: keyword.extensionID, content: content,
                                                     description: item["description"] as? String ?? content,
                                                     rank: rows.count))
        }
        return rows
    }

    private var cache: [BrowserProfileID: [OmnibarKeyword]] = [:]

    func keywords(profile: BrowserProfileID, browser: Int32, shim: CEFShimLibrary) -> [OmnibarKeyword] {
        if let cached = cache[profile] { return cached }
        let keywords = shim.takeString(shim.omniboxKeywords(browser)).map(Self.keywords(json:)) ?? []
        cache[profile] = keywords
        return keywords
    }

    /// Extensions changed (installed, removed, enabled, disabled).
    func invalidate() {
        cache.removeAll()
    }

    func started(browser: Int32, extensionID: String, shim: CEFShimLibrary) {
        _ = shim.omniboxInput(browser, extensionID, 0, "", 0)
    }

    func entered(browser: Int32, extensionID: String, text: String, disposition: OmnibarDisposition, shim: CEFShimLibrary) {
        let value: Int32 = switch disposition {
        case .currentTab: 0
        case .newForegroundTab, .newWindow: 1
        case .newBackgroundTab: 2
        }
        _ = shim.omniboxInput(browser, extensionID, 2, text, value)
    }

    func ended(browser: Int32, extensionID: String, shim: CEFShimLibrary) {
        _ = shim.omniboxInput(browser, extensionID, 3, "", 0)
    }

    /// Sends the text; returns the extension's suggestion JSON, or nil when
    /// it does not listen or does not answer in time.
    func suggestions(browser: Int32, extensionID: String, text: String, shim: CEFShimLibrary) async -> String? {
        let request = nextRequest
        nextRequest &+= 1
        guard shim.omniboxInput(browser, extensionID, 1, text, request) == 1 else { return nil }
        return try? await replies.reply(for: request, timeout: Self.suggestionTimeout) {
            BrowserTabError.timedOut("omnibox suggestions")
        }
    }

    /// OMNIBOX_SUGGESTIONS: resumes the request's waiter (late ones drop).
    func suggestionsArrived(requestID: Int32, extensionID: String, json: String) {
        replies.resolve(requestID, with: .success(json))
    }
}
