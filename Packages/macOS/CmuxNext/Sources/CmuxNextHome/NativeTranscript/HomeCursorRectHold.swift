import AppKit
import CmuxNextDesign

/// Home's typing hold for cursor rects (MessagesLab 409694f's LabWindow, scoped to Home): while
/// keys go to a Home compose field, the cursor-rect invalidations of the views inside that field
/// wait for the next pointer event.
///
/// The TextKit 2 views inside the field invalidate their cursor rects on every typed character.
/// AppKit rebuilt the window's cursor rects at the next event and the window server answered with
/// a mouse-exited, a mouse-entered and about two cursor-update events per key for the I-beam under
/// the still pointer, each a synchronous window-server routing call (Home on cmux-lawrence-2: 95
/// keys gave 95 / 95 / 190 of them and more missed frames than with the pointer outside).
///
/// Only views inside a registered Home field are held, and only after a key went to that field
/// while it is the first responder (the field hides the pointer until it moves). A terminal, a
/// browser or any other view is never inside a Home field, so its invalidations pass at once. The
/// held ones go back to the window before the first non-key event (move, enter, exit, cursor
/// update, click, scroll), at a key change of the window, when a key goes to another view or code
/// moves the focus, when the field invalidates its own rects (it grew or shrank), and before a Home
/// view leaves the window.
@MainActor
final class HomeCursorRectHold: CursorRectHoldPolicy {
    private struct Weak { weak var view: NSView? }
    private weak var window: NSWindow?
    private var roots: [Weak] = []
    private var held: [Weak] = []
    private var typing = false
    /// The field the last key went to: only its subviews are held.
    private weak var typingField: NSTextView?
    private var releasing = false

    private init(window: NSWindow) { self.window = window }

    /// `window`'s hold, made and installed on first use; nil when the window hosts no policy or
    /// already hosts another pane's. The window keeps it weakly: the Home views that use it keep it.
    static func hold(for window: NSWindow) -> HomeCursorRectHold? {
        guard let host = window as? any CursorRectHoldHosting else { return nil }
        if let mine = host.cursorRectHold as? HomeCursorRectHold { return mine }
        guard host.cursorRectHold == nil else { return nil }
        let hold = HomeCursorRectHold(window: window)
        host.cursorRectHold = hold
        return hold
    }

    /// A Home view whose compose field may be held (its descendants: the field and its subviews).
    func add(_ root: NSView) {
        roots.removeAll { $0.view == nil || $0.view === root }
        roots.append(Weak(view: root))
    }

    /// `root` is about to leave the window (still in it): what it held goes back first.
    func remove(_ root: NSView) {
        release()
        roots.removeAll { $0.view == nil || $0.view === root }
    }

    func windowWillSend(_ event: NSEvent, in window: NSWindow) {
        switch event.type {
        case .keyDown:
            // A key to any other view gives the held ones back; a key to a Home field starts the hold.
            guard let field = homeField(in: window) else { release(); return }
            if field !== typingField { release() }
            typingField = field
            typing = true
        case .keyUp, .flagsChanged, .appKitDefined, .systemDefined, .applicationDefined, .periodic: break
        default: release()
        }
    }

    func holdsInvalidation(for view: NSView, in window: NSWindow) -> Bool {
        guard !releasing, typing else { return false }
        guard let field = homeField(in: window), field === typingField else { release(); return false }
        // The field's own rects change (it grew or shrank): the views inside it follow now.
        if view === field { release(keepTyping: true); return false }
        guard view.isDescendant(of: field) else { return false }
        if !held.contains(where: { $0.view === view }) { held.append(Weak(view: view)) }
        return true
    }

    func windowKeyStateWillChange(_ window: NSWindow) { release() }

    func firstResponderDidChange(in window: NSWindow) {
        if typing, window.firstResponder !== typingField { release() }
    }

    /// The first responder when it is an editable text view inside a registered Home view (the
    /// compose field; a read-only text view does not hide the pointer while keys move in it).
    private func homeField(in window: NSWindow) -> NSTextView? {
        guard let field = window.firstResponder as? NSTextView, field.isEditable else { return nil }
        return roots.contains { $0.view.map { field.isDescendant(of: $0) } ?? false } ? field : nil
    }

    private func release(keepTyping: Bool = false) {
        if !keepTyping { typing = false; typingField = nil }
        guard !held.isEmpty, let window else { held.removeAll(); return }
        let views = held.compactMap(\.view)
        held.removeAll()
        releasing = true
        defer { releasing = false }
        for v in views where v.window === window { window.invalidateCursorRects(for: v) }
    }
}
