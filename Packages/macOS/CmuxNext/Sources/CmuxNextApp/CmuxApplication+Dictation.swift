import AppKit
import CmuxNextAgentPane
import ObjectiveC

extension CmuxApplication {
    /// Start Dictation: Edit ▸ Start Dictation and its Globe-D key equivalent, which AppKit adds to
    /// the Edit menu with NSApplication as its target, so no responder sees the action. An agent
    /// pane whose page has the keyboard takes it for its own dictation
    /// (``AgentPaneView/takeStartDictation(in:sender:)``, `agent.systemDictation` off); anything
    /// else gets macOS's dictation, NSApplication's own `startDictation:`.
    @objc(startDictation:) func startDictation(_ sender: Any?) {
        if AgentPaneView.takeStartDictation(in: keyWindow, sender: sender) { return }
        let action = #selector(startDictation(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, action) else { return }
        typealias StartDictation = @convention(c) (NSApplication, Selector, Any?) -> Void
        unsafeBitCast(method_getImplementation(method), to: StartDictation.self)(self, action, sender)
    }
}
