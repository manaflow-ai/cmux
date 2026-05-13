import AppKit
import SwiftUI

struct WeakOmnibarNativeTextField {
    weak var field: OmnibarNativeTextField?
}

@MainActor
final class BrowserOmnibarNativeFieldRegistry {
    static let shared = BrowserOmnibarNativeFieldRegistry()

    private var fields: [UUID: [WeakOmnibarNativeTextField]] = [:]

    deinit {}

    func register(_ field: OmnibarNativeTextField, panelId: UUID) {
        var entries = fields[panelId] ?? []
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        entries.append(WeakOmnibarNativeTextField(field: field))
        fields[panelId] = entries
    }

    func unregister(_ field: OmnibarNativeTextField, panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        fields[panelId] = entries.isEmpty ? nil : entries
    }

    func field(for panelId: UUID?) -> OmnibarNativeTextField? {
        guard let panelId else { return nil }
        pruneDeadEntries(for: panelId)
        return fields[panelId]?.reversed().compactMap(\.field).first
    }

    func field(for panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
        guard let panelId else { return nil }
        pruneDeadEntries(for: panelId)
        guard let entries = fields[panelId] else { return nil }
        let liveFields = entries.reversed().compactMap(\.field)
        return liveFields.first { $0.window === window } ?? liveFields.first
    }

    private func pruneDeadEntries(for panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { $0.field == nil }
        fields[panelId] = entries.isEmpty ? nil : entries
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

    deinit {}

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
