public import Foundation
import WebKit

/// What an agent chat works on (#16620): its session's cwd and the URLs its
/// transcript mentions, dev servers first, then pull requests, newest first.
/// A terminal or browser tab opened from the chat starts from it.
public nonisolated struct AgentPaneContext: Sendable, Equatable {
    public var cwd: String?
    public var urls: [URL]

    public init(cwd: String? = nil, urls: [URL] = []) {
        self.cwd = cwd
        self.urls = urls
    }

    /// The page's `pane.context` answer (`paneContext.ts`).
    init?(page value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        urls = (object["urls"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}

nonisolated extension AgentPaneContext {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    /// Whether an agent's cwd, which comes from its page, is an absolute path to a directory on
    /// this Mac (a remote agent's folder is not one).
    public static func isLocalDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && AcpmuxPathPolicy.isDirectory(path)
    }

    /// The dev server a terminal shows (#16620): the newest localhost URL in
    /// `text`, for a browser tab opened from it. Same rules as `paneContext.ts`:
    /// `0.0.0.0` becomes `localhost`, trailing punctuation is not part of the URL.
    public static func devServer(in text: String?) -> URL? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        for url in links.reversed() {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
                  localHosts.contains(host) || host.hasSuffix(".localhost"),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            if host == "0.0.0.0" { parts.host = "localhost" }
            while let last = parts.path.last, ".,;:!?".contains(last) { parts.path.removeLast() }
            return parts.url
        }
        return nil
    }
}

extension AgentPaneView {
    /// Where a terminal opened from this chat starts (#16620, #22225): its working folder, only as
    /// an absolute path to a directory on this Mac (a remote agent's folder is not one); else nil.
    public func terminalFolder() async -> String? {
        guard let cwd = await workingContext()?.cwd, AgentPaneContext.isLocalDirectory(cwd) else { return nil }
        return cwd
    }

    /// Asks the page what its chat works on. Nil before the page connects,
    /// or when it does not answer within `limit`. An agent-home cwd never
    /// leaves the chat (``AgentPaneModel/folderForOtherTabs(_:)``).
    public func workingContext(limit: Duration = .seconds(1)) async -> AgentPaneContext? {
        let read: AgentPaneContext? = await agentPaneFirst(within: limit) { [weak self] in
            guard let self else { return nil }
            let script = "const read = window.cmuxAcpmuxActions?.['pane.context']; return read ? await read({}) : null;"
            let value = try? await self.callPageScript(script)
            return AgentPaneContext(page: value)
        }
        guard var context = read else { return nil }
        context.cwd = model.folderForOtherTabs(context.cwd)
        return context
    }
}
