public import CmuxHomeCore
public import CoreGraphics
public import Foundation
import QuartzCore

extension HomeController {
    /// Applies host input. Returns the intent it emitted through `onIntent`
    /// (only `.send` emits one, and only for a non-empty draft).
    @discardableResult
    public func handle(_ input: HomeInput) -> HomeIntent? {
        switch input {
        case .scroll(let dy, let phase, _):
            if phase == .began || phase == .mayBegin { scene.momentum = nil }
            if scene.scroll(by: dy / zoom) { afterViewportChange() }
        case .fling(let velocity):
            scene.beginMomentum(velocity: velocity / zoom, at: CACurrentMediaTime())
        case .insertText(let s, let range): edit { $0.insert(s, replacing: range) }
        case .setMarkedText(let s, let selected, let range): edit { $0.setMarked(s, selected: selected, replacing: range) }
        case .unmarkText: edit { $0.unmark() }
        case .deleteBackward: edit { $0.deleteBackward() }
        case .insertNewline: edit { $0.insert("\n") }
        case .moveCaret(let d): edit { $0.moveCaret(by: d) }
        case .send: return send()
        }
        return nil
    }

    /// Hosts without system momentum: one display frame. Run the display link
    /// only while this returns true.
    public func stepMomentum(timestamp: CFTimeInterval) -> Bool {
        let more = scene.stepMomentum(at: timestamp)
        afterViewportChange()
        return more
    }

    /// The owner refused a send before logging it (for example while offline,
    /// where nothing queues): the field gets its text back if it is still empty.
    public func restoreDraft(for key: IdempotencyKey) {
        guard let pending = pendingSend, pending.intent.key == key else { return }
        pendingSend = nil
        if scene.hostedField != nil {
            onRestoreDraft(pending.text)
            return
        }
        guard scene.compose.text.isEmpty else { return }
        scene.compose.reset(pending.text)
        fieldChanged(send: false)
        onAccessibilityChange()
    }

    // MARK: Text input geometry (IME candidate window, NSTextInputClient, UITextInput)

    public var draft: String { scene.compose.text }
    public var selectedRange: NSRange { scene.compose.editor.selection }
    public var markedRange: NSRange? { scene.compose.editor.marked }
    /// The caret in viewport points, top-left origin.
    public var caretRect: CGRect { toHost(scene.compose.caretRect) }
    /// The compose field in viewport points; hosts place their buttons beside it.
    public var fieldRect: CGRect { toHost(scene.hostedField ?? scene.compose.fieldRect) }
    /// Hide while the host's text input is not focused.
    public var showsCaret: Bool {
        get { scene.compose.showsCaret }
        set { scene.compose.showsCaret = newValue }
    }

    // MARK: Internals

    private func edit(_ change: (inout ComposeEditor) -> Void) {
        let before = scene.compose.text
        guard scene.compose.edit(change) else { return }
        if scene.compose.text != before { fieldChanged(send: false) }
        scene.compose.restartCaret(begin: scene.now, sent: false, motion: scene.motion)
        onAccessibilityChange()
    }

    /// The draft as a send: trimmed text, one text part, a fresh idempotency key.
    private func send() -> HomeIntent? {
        guard scene.compose.editor.marked == nil else {
            edit { $0.unmark() }
            return nil
        }
        let text = scene.compose.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let intent = HomeIntent(op: .sendMessage(conversation: conversation, parts: [.text(trimmed)]))
        pendingSend = (intent, text, scene.compose.fieldRect)
        scene.pinned = true
        scene.compose.reset("")
        fieldChanged(send: true)
        scene.compose.restartCaret(begin: scene.now, sent: true, motion: scene.motion)
        onIntent(intent)
        onAccessibilityChange()
        return intent
    }

    /// The field takes the height its text needs; the transcript above
    /// follows with the field's spring.
    func fieldChanged(send: Bool) {
        let oldTop = scene.compose.fieldTop
        let begin = scene.now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.compose.settle(send: send, begin: begin, motion: scene.motion)
        let change = TranscriptChange.field(send: send)
        scene.placeMask(oldTop: oldTop, element: scene.motion(change.element), begin: begin)
        CATransaction.commit()
        guard oldTop != scene.compose.fieldTop || send, scene.size.width > 0 else { return }
        scene.commit(nil, change: change)
    }
}
