public import AppKit
import IOSurface

/// The phone's screen inside a phone tab. It shows either the simulator's
/// own IOSurface (live: each SimulatorKit frame only marks the layer's
/// contents changed, no copy) or a still image. Mouse down, drag and up are
/// touches; typed keys go to the phone while it has focus. It reports when it
/// can be seen, so the tab stops frames while hidden.
@MainActor
public final class PhoneScreenView: NSView {
    private let content = CALayer()
    private var contentSize: CGSize = .zero
    private var occlusion: Task<Void, Never>?
    private var lastVisible: Bool?

    /// A touch at a 0...1 screen point (top-left origin).
    var onTouch: (@MainActor (PhoneTouch.Phase, CGPoint) -> Void)?
    /// A key change (Mac key code, down) while the screen has focus; return false to pass it on.
    var onKey: (@MainActor (UInt16, Bool) -> Bool)?
    /// Called when the screen becomes visible or hidden (tab switch, window occlusion, minimize).
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        content.contentsGravity = .resizeAspect
        content.cornerRadius = 18
        content.masksToBounds = true
        content.backgroundColor = NSColor.black.cgColor
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a live surface. Call again with the same surface for every frame.
    func show(surface: IOSurface) {
        let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if content.contents as AnyObject? !== surface {
            content.contents = surface
        } else {
            content.setContentsChanged()
        }
        CATransaction.commit()
        if size != contentSize {
            contentSize = size
            needsLayout = true
        }
    }

    /// Shows a still frame (the `simctl` / `screencap` fallback).
    func show(image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
        contentSize = image?.size ?? .zero
        needsLayout = true
    }

    /// The screen as drawn now (aspect fit), for mapping clicks.
    var mapping: PhoneScreenMapping { PhoneScreenMapping(screen: contentSize, view: bounds.size) }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = mapping.drawnRect == .zero ? bounds : mapping.drawnRect
        CATransaction.commit()
    }

    // MARK: Input

    override public var acceptsFirstResponder: Bool { onKey != nil }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        touch(.began, event)
    }

    override public func mouseDragged(with event: NSEvent) { touch(.moved, event) }
    override public func mouseUp(with event: NSEvent) { touch(.ended, event) }

    private func touch(_ phase: PhoneTouch.Phase, _ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Clamp drags that leave the screen so the touch still ends on it.
        let rect = mapping.drawnRect
        let clamped = CGPoint(x: min(max(local.x, rect.minX), rect.maxX), y: min(max(local.y, rect.minY), rect.maxY))
        guard let point = mapping.normalized(viewPoint: phase == .began ? local : clamped) else { return }
        onTouch?(phase, point)
    }

    override public func keyDown(with event: NSEvent) {
        // Command shortcuts stay with cmux; everything else types on the phone.
        if event.modifierFlags.contains(.command) || onKey?(event.keyCode, true) != true { super.keyDown(with: event) }
    }

    override public func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || onKey?(event.keyCode, false) != true { super.keyUp(with: event) }
    }

    // MARK: Visibility

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusion?.cancel()
        occlusion = nil
        if let window {
            occlusion = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification, object: window) {
                    self?.reportVisibility()
                }
            }
        }
        reportVisibility()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        reportVisibility()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        reportVisibility()
    }

    /// True while some part of the screen can be seen.
    public var isOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    func reportVisibility() {
        let visible = isOnScreen
        guard visible != lastVisible else { return }
        lastVisible = visible
        onVisibilityChange?(visible)
    }

    /// Stops watching the window; the tab calls this when it closes.
    func close() {
        occlusion?.cancel()
        occlusion = nil
    }
}
