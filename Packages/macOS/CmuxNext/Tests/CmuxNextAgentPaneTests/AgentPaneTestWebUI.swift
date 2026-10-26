import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextInput
import CmuxNextPages

/// A memory pressure source that never reports pressure: the agent pane tests do not drive the
/// page lifecycle.
private nonisolated final class QuietMemoryPressureSource: MemoryPressureSource {
    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {}
    func cancel() {}
    var currentLevel: MemoryPressureLevel { .normal }
}

extension WebUIHost {
    /// A page host for an agent pane test: `chromium` makes its Chromium pages (nil keeps every page
    /// on WebKit), with no open panel and its own registry.
    static func agentPaneTestHost(chromium: (any PageChromiumHosting)? = nil) -> WebUIHost {
        WebUIHost(chromium: chromium, openPanel: nil,
                  memoryPressure: MemoryPressureEvents(source: QuietMemoryPressureSource()))
    }
}

extension AgentPaneGestureRouter {
    /// A gesture router over a fresh input tap, for a test that never dispatches through one.
    static func testing() -> AgentPaneGestureRouter { AgentPaneGestureRouter(input: InputEventTap()) }
}
