public import AppKit
public import CmuxNextActions
import CmuxNextDesign
import ImageIO
import UniformTypeIdentifiers

/// Point at Element over cmux's native UI (ask-5077a4ec48): the element under the pointer, its containers, and the
/// one outline that marks it. It holds nothing until the first move of a pick and `clear()` drops it all, so an idle
/// app keeps no hit-test tree, observer or overlay (shadow-leo's rule for bringing native UI back).
@MainActor
public final class UIPointerNativePicker {
    /// What a key did: walked the outline (`handled`), picked (`pick`), or is not the picker's (`pass`).
    public enum KeyResult: Equatable { case pass, handled, pick(UIPointerNativeElement) }

    /// How the outline draws (the gallery compares the others).
    public var look: UIPointerHighlightView.Look = .outline
    /// The element outlined now.
    public var current: UIPointerNativeElement? { hover?.current }
    /// The outlined element and its containers outward.
    public var path: [UIPointerNativeElement] { hover.map { Array($0.elements[$0.level...]) } ?? [] }
    /// The window the outline is in (a key pick crops from it).
    public var window: NSWindow? { hover?.window }
    /// Whether an outline is up (tests: none while idle).
    var isShowing: Bool { hover?.highlight.map { !$0.isDismissed } ?? false }

    /// The element under the pointer and its containers outward (`elements`), the one shown (`level`), its
    /// outline, and a hold that keeps a right-clicked element through the move back from its menu.
    private struct Hover {
        weak var window: NSWindow?
        var elements: [UIPointerNativeElement]
        var level = 0
        var highlight: OverlayHandle?
        var outline: UIPointerHighlightView?
        var hold: (point: NSPoint, uptime: TimeInterval)?
        var lastPoint: NSPoint?
        var current: UIPointerNativeElement? { elements.indices.contains(level) ? elements[level] : nil }
    }

    private var hover: Hover?
    /// The last point that named nothing (`hover` is nil then), so a pointer resting over unnamed views runs no
    /// hit-test per move either.
    private var emptyAt: (window: ObjectIdentifier, point: NSPoint)?
    /// How far (points) and how long (seconds) a right-clicked element holds against the pointer.
    private static let holdSlop: CGFloat = 24
    private static let holdGrace: TimeInterval = 0.35

    public init() {}

    /// Outlines what is under `point` (screen) in `window`; `releasingHold` (a press) ends a menu's hold first.
    public func hover(at point: NSPoint, in window: NSWindow, releasingHold: Bool = false) {
        if var held = hover, let hold = held.hold, held.window === window, !releasingHold {
            // The right-clicked element holds while the pointer comes back from its menu.
            let moved = hypot(point.x - hold.point.x, point.y - hold.point.y)
            if moved < Self.holdSlop || ProcessInfo.processInfo.systemUptime - hold.uptime < Self.holdGrace { return }
            held.hold = nil
            hover = held
        }
        if hover?.window === window, hover?.lastPoint == point, hover?.hold == nil { return }
        if hover == nil, let empty = emptyAt, empty.window == ObjectIdentifier(window), empty.point == point { return }
        let elements = UIPointerNativeElement.elements(at: window.convertPoint(fromScreen: point), in: window) { $0 is UIPointerHighlightView }
        show(elements, in: window, hold: nil)
        hover?.lastPoint = point
        if hover == nil { emptyAt = (ObjectIdentifier(window), point) }
    }

    /// Starts on a native menu's object (a menu run carries no point) and holds it while the pointer leaves the menu.
    @discardableResult
    public func start(on target: ActionTargetRef, in window: NSWindow) -> Bool {
        guard let element = UIPointerNativeElement.find(target, in: window) else { return false }
        let outward = UIPointerNativeElement.elements(at: NSPoint(x: element.frame.midX, y: element.frame.midY), in: window) { $0 is UIPointerHighlightView }
        let from = outward.firstIndex { $0.identifier == element.identifier }.map { $0 + 1 } ?? outward.endIndex
        show([element] + outward[from...], in: window, hold: (NSEvent.mouseLocation, ProcessInfo.processInfo.systemUptime))
        return true
    }

    /// Up walks out to the outlined element's container, Down back in, Return picks it.
    public func key(_ keyCode: UInt16) -> KeyResult {
        guard var current = hover else { return .pass }
        switch keyCode {
        case 126: current.level = min(current.level + 1, current.elements.count - 1)
        case 125: current.level = max(current.level - 1, 0)
        case 36, 76: return current.current.map { .pick($0) } ?? .handled
        default: return .pass
        }
        current.hold = nil
        hover = current
        placeOutline()
        return .handled
    }

    /// Drops the outline and everything the pick held.
    public func clear() {
        hover?.highlight?.dismiss()
        hover = nil
        emptyAt = nil
    }

    /// The window image cut to `rect` (window coordinates, bottom-left origin), as PNG.
    public static func crop(_ image: CGImage, rect: NSRect, window: NSWindow) -> Data? {
        let scale = Double(image.width) / max(Double(window.frame.width), 1)
        let cut = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                         width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !cut.isEmpty, let cropped = image.cropping(to: cut) else { return nil }
        return png(cropped)
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Outlines `elements[0]` in `window`, reusing the outline when it is already there.
    private func show(_ elements: [UIPointerNativeElement], in window: NSWindow, hold: (point: NSPoint, uptime: TimeInterval)?) {
        guard let first = elements.first else { clear(); return }
        if var current = hover, current.window === window {
            // The same chain (a jitter, or a move inside the element) keeps the level Up and Down chose.
            if current.elements == elements {
                current.hold = hold ?? current.hold
                hover = current
                return
            }
            let same = current.current == first && current.level == 0
            current.elements = elements
            current.level = 0
            current.hold = hold ?? current.hold
            hover = current
            if !same { placeOutline() }
            return
        }
        clear()
        hover = Hover(window: window, elements: elements, hold: hold)
        placeOutline()
    }

    private func placeOutline() {
        guard var current = hover, let window = current.window, let element = current.current else { return }
        let rect = UIPointerHighlightView.frame(around: element.frame, in: window)
        if let outline = current.outline, let highlight = current.highlight, !highlight.isDismissed {
            outline.show(element, look: look, outlineIn: rect, around: element.frame)
            highlight.update(anchor: rect)
            return
        }
        let outline = UIPointerHighlightView(frame: NSRect(origin: .zero, size: rect.size))
        outline.show(element, look: look, outlineIn: rect, around: element.frame)
        current.outline = outline
        current.highlight = WindowOverlayHost.host(for: window).present(outline, options: OverlayOptions(
            kind: .attached, anchor: rect, passesThroughClicks: true))
        hover = current
    }
}
