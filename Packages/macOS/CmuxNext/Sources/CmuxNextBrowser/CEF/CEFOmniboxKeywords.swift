import CmuxNextCompat
import Foundation

/// chrome.omnibox keyword sessions over the fork (API 12): keyword lists,
/// session events, and suggestions matched to their request by id, each
/// with a deadline (architecture.md 5a).
@MainActor final class CEFOmniboxKeywords {
    /// Longest wait for an extension's suggestions; later rows are dropped.
    static let suggestionTimeout: Duration = .seconds(3)

    private let replies: CEFReplyWaiters<Int32, String>
    private var nextRequest: Int32 = 1

    /// `clock`: the suggestions' deadlines.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        replies = CEFReplyWaiters(clock: clock)
    }

    /// Decodes `cmux_omnibox_keywords` JSON.
    nonisolated static func keywords(json: String) -> [OmnibarKeyword] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.blockingJSONObject(with: data) as? [[String: Any]] else { return [] }
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
              let items = try? JSONSerialization.blockingJSONObject(with: data) as? [[String: Any]] else { return rows }
        for item in items {
            guard let content = item["content"] as? String, !content.isEmpty,
                  !rows.contains(where: { $0.content == content }) else { continue }
            rows.append(OmnibarKeyword.suggestionRow(extensionID: keyword.extensionID, content: content,
                                                     description: item["description"] as? String ?? content,
                                                     rank: rows.count))
        }
        return rows
    }

    // memory: fixed: one entry per browser profile, each the omnibox keywords of its installed
    // extensions (a few short strings per extension), emptied whenever extensions change (`invalidate`).
    private var cache: [BrowserProfileID: [OmnibarKeyword]] = [:]

    /// The profile's keywords, cached until extensions change. A mirror with no value (in host mode
    /// one an extension change made pending, or one the host has not pushed yet) is not cached: the
    /// next omnibar step reads it again.
    func keywords(profile: BrowserProfileID, browser: Int32, shim: CEFShimLibrary) -> [OmnibarKeyword] {
        if let cached = cache[profile] { return cached }
        guard let json = shim.omniboxKeywords(browser) else { return [] }
        let keywords = Self.keywords(json: json)
        cache[profile] = keywords
        return keywords
    }

    /// Extensions changed (installed, removed, enabled, disabled).
    func invalidate() {
        cache.removeAll()
    }

    func started(browser: Int32, extensionID: String, runtime: CEFRuntime) {
        notify(browser, extensionID, .started, "", 0, runtime: runtime)
    }

    func entered(browser: Int32, extensionID: String, text: String, disposition: OmnibarDisposition, runtime: CEFRuntime) {
        let value: Int32 = switch disposition {
        case .currentTab: 0
        case .newForegroundTab, .newWindow: 1
        case .newBackgroundTab: 2
        }
        notify(browser, extensionID, .entered, text, value, runtime: runtime)
    }

    func ended(browser: Int32, extensionID: String, runtime: CEFRuntime) {
        notify(browser, extensionID, .ended, "", 0, runtime: runtime)
    }

    /// Sends the text; returns the extension's suggestion JSON, or nil when it does not listen or
    /// does not answer in time. Whether it listens is the call's answer (OnInputChanged's result in
    /// chrome/browser/extensions/api/omnibox/omnibox_api.cc, which KeywordProvider reads before it
    /// waits, components/omnibox/browser/keyword_provider.cc): in process at once, in host mode in
    /// the host's REPLY, which ends the wait for an extension that does not listen instead of the
    /// suggestion timeout.
    func suggestions(browser: Int32, extensionID: String, text: String, runtime: CEFRuntime) async -> String? {
        let request = nextRequest
        nextRequest &+= 1
        let sent = runtime.sendAsync { $0.omniboxInput(browser, extensionID, Event.changed.rawValue, text, request) }
        switch sent {
        case .unsent:
            return nil
        case .now(let listens):
            guard listens == 1 else { return nil }
        case .later:
            // The REPLY comes in a later turn than this one, which registers the wait below.
            runtime.whenAnswered(sent, label: "omnibox input") { [weak self] listens in
                guard listens != 1 else { return }
                self?.replies.resolve(request, with: .failure(BrowserTabError.closed))
            }
        }
        return try? await replies.reply(for: request, timeout: Self.suggestionTimeout) {
            BrowserTabError.timedOut("omnibox suggestions")
        }
    }

    /// OMNIBOX_SUGGESTIONS: resumes the request's waiter (late ones drop).
    func suggestionsArrived(requestID: Int32, extensionID: String, json: String) {
        replies.resolve(requestID, with: .success(json))
    }

    /// `cmux_shim_omnibox_input`'s session events, in the fork's order.
    private enum Event: Int32 {
        case started = 0, changed, entered, ended
    }

    /// A session event that needs no answer. Its REPLY is still taken (with a deadline), so the
    /// host's answer settles its token.
    private func notify(_ browser: Int32, _ extensionID: String, _ event: Event, _ text: String, _ value: Int32,
                        runtime: CEFRuntime) {
        let sent = runtime.sendAsync { $0.omniboxInput(browser, extensionID, event.rawValue, text, value) }
        runtime.whenAnswered(sent, label: "omnibox input") { _ in }
    }
}
