import AppKit

/// Text-field delegate for a JS sidebar `TextField` node: turns AppKit editing
/// callbacks into `edit`, `submit` and `cancel` scene events.
///
/// Both Return and focus loss end editing and send `submit`. Only a submit
/// that Return caused carries ``SidebarJSRuntime/submitTriggerKey`` =
/// ``SidebarJSRuntime/submitTriggerReturn``, which is what lets the runtime
/// treat it as a user gesture. A focus-loss submit (the user clicking into the
/// terminal, or a programmatic focus move) must never open that window.
@MainActor
final class SceneTextFieldCoordinator: NSObject, NSTextFieldDelegate {
    private let nodeId: String
    private let sink: SceneEventSink
    private var finished = false
    /// Set when the field editor runs `insertNewline:` (the Return key), so
    /// the editing session that ends next is attributed to Return.
    private var returnPressed = false

    init(nodeId: String, sink: SceneEventSink) {
        self.nodeId = nodeId
        self.sink = sink
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finished = true
            sink.send(nodeId, "cancel", [:])
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Let AppKit end editing as usual; controlTextDidEndEditing sends
            // the submit and reads this flag.
            returnPressed = true
        }
        return false
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        // A persistent field (panel search box) is re-entered after a
        // previous commit; a new editing session must be able to commit
        // again.
        finished = false
        returnPressed = false
    }

    func controlTextDidChange(_ notification: Notification) {
        // Live per-keystroke event for filter-as-you-type consumers
        // (fields without an edit handler never see it - the JS side
        // only registers handlers it was given).
        guard let field = notification.object as? NSTextField else { return }
        sink.send(nodeId, "edit", ["text": field.stringValue])
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Return AND focus loss (clicking outside) both land here; both
        // commit. Escape set `finished` above and must not also submit.
        let viaReturn = returnPressed
        returnPressed = false
        guard !finished, let field = notification.object as? NSTextField else { return }
        finished = true
        var payload: [String: Any] = ["text": field.stringValue]
        if viaReturn {
            payload[SidebarJSRuntime.submitTriggerKey] = SidebarJSRuntime.submitTriggerReturn
        }
        sink.send(nodeId, "submit", payload)
    }
}
