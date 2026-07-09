import AppKit
import SwiftUI

private final class WeakOmnibarNativeTextField {
    weak var field: OmnibarNativeTextField?

    init(_ field: OmnibarNativeTextField) {
        self.field = field
    }
}

@MainActor
final class BrowserOmnibarNativeFieldRegistry {
    static let shared = BrowserOmnibarNativeFieldRegistry()

    // Ownership invariant: OmnibarNativeTextField.panelId is the single source
    // of truth for field-to-panel ownership, and a live omnibar field owns its
    // current field editor. AppKit's field-editor responder chain is the normal
    // lookup path, but it can keep a stale nextResponder during browser
    // focus/layout transitions. This weak registry is only a live-field lookup
    // cache for those stale-responder windows; it does not create ownership.
    private var fields: [UUID: [WeakOmnibarNativeTextField]] = [:]

    func register(_ field: OmnibarNativeTextField, panelId: UUID) {
        var entries = fields[panelId] ?? []
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        entries.append(WeakOmnibarNativeTextField(field))
        fields[panelId] = entries
    }

    func unregister(_ field: OmnibarNativeTextField, panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        if entries.isEmpty {
            fields.removeValue(forKey: panelId)
        } else {
            fields[panelId] = entries
        }
    }

    func field(for panelId: UUID?, in window: NSWindow? = nil) -> OmnibarNativeTextField? {
        guard let panelId else { return nil }
        pruneDeadEntries(for: panelId)
        guard let entries = fields[panelId] else { return nil }
        let liveFields = entries.reversed().compactMap(\.field)
        if let window {
            return liveFields.first(where: { $0.window === window })
        }
        return liveFields.first(where: { $0.window != nil }) ?? liveFields.first
    }

    func fieldOwningEditor(_ editor: NSTextView, in window: NSWindow? = nil) -> OmnibarNativeTextField? {
        for panelId in Array(fields.keys) {
            pruneDeadEntries(for: panelId)
        }

        let liveFields = fields.values.flatMap { entries in
            entries.reversed().compactMap(\.field)
        }
        if let window,
           let windowField = liveFields.first(where: { $0.window === window && $0.currentEditor() === editor }) {
            return windowField
        }
        if let registeredField = liveFields.first(where: { $0.currentEditor() === editor }) {
            return registeredField
        }

        guard let root = window?.contentView?.superview ?? window?.contentView else {
            return nil
        }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let field = view as? OmnibarNativeTextField,
               field.currentEditor() === editor {
                return field
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func pruneDeadEntries(for panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { $0.field == nil }
        if entries.isEmpty {
            fields.removeValue(forKey: panelId)
        } else {
            fields[panelId] = entries
        }
    }
}

extension BrowserOmnibarNativeFieldRegistry {
    func omnibarPanelId(for responder: NSResponder?) -> UUID? {
        omnibarField(for: responder)?.panelId
    }

    func omnibarField(panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
        if let registeredField = field(for: panelId, in: window) {
            return registeredField
        }
        guard let panelId, let root = window?.contentView?.superview ?? window?.contentView else {
            return nil
        }

        // Fallback for SwiftUI/AppKit reconnect windows where the live native field
        // has been attached but registration has not yet observed it.
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let field = view as? OmnibarNativeTextField, field.panelId == panelId {
                return field
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    @discardableResult
    func prepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
        guard let field = omnibarField(for: responder),
              field.panelId == panelId else {
            return false
        }
        field.suppressNextFocusReacquireOnEndEditing = true
        return true
    }

    private func omnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
        guard let responder else { return nil }

        if let field = responder as? OmnibarNativeTextField {
            return field
        }

        if let editor = responder as? NSTextView, editor.isFieldEditor {
            if let field = fieldOwningEditor(editor, in: editor.window) {
                return field
            }

            if let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
               field.currentEditor() === editor {
                return field
            }

        }

        return nil
    }
}

@MainActor
final class BrowserOmnibarInteractionView: NSView {
    var panelId: UUID?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        guard BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) != nil else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func cursorUpdate(with event: NSEvent) {
        setIBeamCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        setIBeamCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        setIBeamCursor()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDragged(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDown(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDragged(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseUp(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    private func setIBeamCursor() {
        NSCursor.iBeam.set()
    }

    private func forwardMouseEvent(
        _ event: NSEvent,
        _ apply: (OmnibarNativeTextField, NSEvent) -> Void
    ) {
        guard let field = BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) else {
            return
        }
        apply(field, event)
    }
}

@MainActor
struct BrowserOmnibarInteractionRepresentable: NSViewRepresentable {
    let panelId: UUID

    func makeNSView(context: Context) -> BrowserOmnibarInteractionView {
        let view = BrowserOmnibarInteractionView(frame: .zero)
        view.panelId = panelId
        return view
    }

    func updateNSView(_ nsView: BrowserOmnibarInteractionView, context: Context) {
        nsView.panelId = panelId
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
