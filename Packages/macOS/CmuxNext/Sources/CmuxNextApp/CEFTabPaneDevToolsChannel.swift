import CmuxNextAgentPane
import CmuxNextBrowser
import Foundation

/// An in-process CEF tab as the DevTools session ``CEFPaneHostBridge``
/// runs on. Prototype glue (no caller yet): a pane page shown in a CEF
/// view gets `CEFPaneHostBridge(channel: CEFTabPaneDevToolsChannel(tab))`
/// installed before its first load, and its handler from
/// `AgentPaneView.makePaneHostHandler()` or the pane's own equivalent.
final class CEFTabPaneDevToolsChannel: PaneDevToolsChannel {
    private weak var tab: CEFTab?

    init(_ tab: CEFTab) {
        self.tab = tab
    }

    func devToolsCall(_ method: String, params: [String: any Sendable]) async throws -> String {
        guard let tab else { throw BrowserTabError.closed }
        return try await tab.devTools(method: method, params: params)
    }

    func devToolsEvents() -> AsyncStream<PaneDevToolsEvent> {
        guard let source = tab?.devToolsEventStream() else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream<PaneDevToolsEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        // task-owner: the returned stream; ending it cancels the relay, and the source ends when the browser closes
        let relay = Task {
            for await event in source { continuation.yield(PaneDevToolsEvent(method: event.method, params: event.params)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }
}
