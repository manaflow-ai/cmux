public import AppKit

/// What automation reads about the omnibar (`debug.omnibar`): the state
/// machine and the field editor side by side, so a test sees both the model
/// and what AppKit shows.
public struct OmnibarDebugSnapshot: Sendable, Equatable {
    public var phase: String
    public var hasFocus: Bool
    /// The focused field shows the steady-state (elided) URL.
    public var elided: Bool
    /// What the model says the field shows, and its selection (UTF-16).
    public var text: String
    public var selection: NSRange?
    /// What the field (or its field editor) actually holds.
    public var fieldText: String
    public var fieldSelection: NSRange?
    public var fieldEditorActive: Bool
    public var rows: [String]
    public var highlighted: Int?
    /// What Copy would put on the pasteboard now (nothing is written).
    public var copyText: String?
}

/// A synthesized mouse gesture over the omnibar text (`debug.mouse`).
public struct OmnibarDebugMouse: Sendable {
    public enum Button: Sendable { case left, right }
    /// Character index the press lands on (the leading edge of that
    /// character; the text length means after the last one).
    public var character: Int
    /// Drag to this character before the release.
    public var dragTo: Int?
    public var clickCount: Int
    public var button: Button

    public init(character: Int, dragTo: Int? = nil, clickCount: Int = 1, button: Button = .left) {
        self.character = character
        self.dragTo = dragTo
        self.clickCount = clickCount
        self.button = button
    }
}

extension AddressBarView {
    public var debugSnapshot: OmnibarDebugSnapshot {
        let state = controller.state
        let presentation = OmnibarPresentation(state)
        let editor = field.currentEditor() as? NSTextView
        let phase = switch state.phase {
        case .idle: "idle"
        case .focused: "focused"
        case .editing: "editing"
        case .committing: "committing"
        }
        return OmnibarDebugSnapshot(
            phase: phase,
            hasFocus: state.hasFocus,
            elided: state.elided,
            text: presentation.text,
            selection: presentation.selection,
            fieldText: editor?.string ?? field.stringValue,
            fieldSelection: editor?.selectedRange(),
            fieldEditorActive: editor != nil,
            rows: presentation.rows.map(\.title),
            highlighted: presentation.highlighted,
            copyText: OmnibarReducer.copyContent(of: state, resolver: suggestionEngine.resolver)?.text
        )
    }

    /// Dispatches a press (and drag) and release over the omnibar text the
    /// way `NSWindow.sendEvent` does for a key window: the hit view becomes
    /// first responder, then gets the press, while the release and drags
    /// wait in the event queue for AppKit's own tracking loop. Never
    /// activates the app or makes the window key. The context menu of a
    /// right-click is skipped (it would run a modal loop). Returns an error.
    public func debugMouse(_ gesture: OmnibarDebugMouse) -> String? {
        guard let window, let contentView = window.contentView else { return "no window" }
        let press = point(forCharacter: gesture.character)
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ at: NSPoint, _ offset: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: now + offset,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: gesture.clickCount, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        }
        let right = gesture.button == .right
        guard let down = event(right ? .rightMouseDown : .leftMouseDown, press, 0) else { return "bad event" }
        var queued: [NSEvent] = []
        if let target = gesture.dragTo, !right {
            let end = point(forCharacter: target)
            for step in 1...4 {
                let t = CGFloat(step) / 4
                let at = NSPoint(x: press.x + (end.x - press.x) * t, y: press.y)
                if let drag = event(.leftMouseDragged, at, 0.01 * Double(step)) { queued.append(drag) }
            }
            if let up = event(.leftMouseUp, end, 0.05) { queued.append(up) }
        } else if let up = event(right ? .rightMouseUp : .leftMouseUp, press, 0.02) {
            queued.append(up)
        }
        guard var hit = contentView.hitTest(contentView.superview?.convert(press, from: nil) ?? press) else { return "no view at the point" }
        guard hit.isDescendant(of: field) else { return "the omnibar text is covered" }
        // While editing, the field editor (inside the field's clip view) owns
        // every press over the text.
        if let editor = field.currentEditor() as? NSTextView { hit = editor }
        if right {
            let editor = (field.cell as? AddressFieldCell)?.editor
            editor?.suppressesContextMenu = true
            defer { editor?.suppressesContextMenu = false }
            pendingFocusSource = .mouse
            defer { pendingFocusSource = nil }
            hit.rightMouseDown(with: down)
            return nil
        }
        for queuedEvent in queued { NSApp.postEvent(queuedEvent, atStart: false) }
        if hit !== window.firstResponder, hit.acceptsFirstResponder {
            pendingFocusSource = .mouse
            window.makeFirstResponder(hit)
            pendingFocusSource = nil
        }
        hit.mouseDown(with: down)
        return nil
    }

    /// Window point on the text baseline's middle at `index`.
    private func point(forCharacter index: Int) -> NSPoint {
        if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
            let length = (editor.string as NSString).length
            let clamped = min(max(index, 0), length)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(clamped, max(length - 1, 0)), length: length == 0 ? 0 : 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let x = (clamped == length ? rect.maxX : rect.minX) + editor.textContainerOrigin.x + 0.5
            return editor.convert(NSPoint(x: x, y: rect.midY + editor.textContainerOrigin.y), to: nil)
        }
        let text = field.attributedStringValue
        let clamped = min(max(index, 0), text.length)
        let prefix = text.attributedSubstring(from: NSRange(location: 0, length: clamped)).size().width
        let origin = field.cell?.titleRect(forBounds: field.bounds).minX ?? 2
        return field.convert(NSPoint(x: origin + prefix + 2 + 0.5, y: field.bounds.midY), to: nil)
    }
}
