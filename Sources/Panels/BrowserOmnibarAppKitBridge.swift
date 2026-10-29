import AppKit
import SwiftUI

private final class WeakOmnibarNativeTextField {
    weak var field: OmnibarNativeTextField?

    init(_ field: OmnibarNativeTextField) {
        self.field = field
    }
}

// AppKit calls the interaction view from hit-testing and responder routing.
// Keep the registry main-thread confined by ownership, but do not mark it
// MainActor-isolated: those framework callbacks do not carry Swift's actor
// executor token even when they arrive on the main thread.
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

// SwiftUI/AppKit can invoke hitTest while reconnecting a hosted view. The view
// is main-thread-owned by its representable, but the override itself must stay
// available to AppKit without a MainActor executor check. Each override below
// is explicitly `nonisolated`; NSView inherits `@MainActor` from NSResponder
// in the Swift 6 SDK even when this class has no explicit actor annotation.
final class BrowserOmnibarInteractionView: NSView {
    var panelId: UUID?
    private var trackingArea: NSTrackingArea?

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var mouseDownCanMoveWindow: Bool { false }

    nonisolated override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    nonisolated required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    nonisolated override func updateTrackingAreas() {
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

    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        guard BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) != nil else {
            return nil
        }
        return self
    }

    nonisolated override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    nonisolated override func cursorUpdate(with event: NSEvent) {
        setIBeamCursor()
    }

    nonisolated override func mouseEntered(with event: NSEvent) {
        setIBeamCursor()
    }

    nonisolated override func mouseMoved(with event: NSEvent) {
        setIBeamCursor()
    }

    nonisolated override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    nonisolated override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDown(with: event)
        }
    }

    nonisolated override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDragged(with: event)
        }
    }

    nonisolated override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseUp(with: event)
        }
    }

    nonisolated override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDown(with: event)
        }
    }

    nonisolated override func rightMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDragged(with: event)
        }
    }

    nonisolated override func rightMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseUp(with: event)
        }
    }

    nonisolated override func otherMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDown(with: event)
        }
    }

    nonisolated override func otherMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDragged(with: event)
        }
    }

    nonisolated override func otherMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseUp(with: event)
        }
    }

    nonisolated override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    nonisolated override func viewDidMoveToWindow() {
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
