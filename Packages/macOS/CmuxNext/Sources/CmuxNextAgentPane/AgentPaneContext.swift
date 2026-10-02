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

extension AgentPaneView {
    /// Asks the page what its chat works on. Nil before the page connects,
    /// or when it does not answer within `limit`.
    public func workingContext(limit: Duration = .seconds(1)) async -> AgentPaneContext? {
        await agentPaneFirst(within: limit) { [weak self] in
            guard let webView = self?.webView else { return nil }
            let script = "const read = window.cmuxAcpmuxActions?.['pane.context']; return read ? await read({}) : null;"
            let value = try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
            return AgentPaneContext(page: value)
        }
    }
}
