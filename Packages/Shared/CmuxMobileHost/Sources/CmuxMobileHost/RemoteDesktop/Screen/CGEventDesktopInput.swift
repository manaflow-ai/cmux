#if os(macOS)
import CmuxBrowserStream
import CmuxRemoteDesktop
import CoreGraphics
import Foundation

/// Injects rd input as HID-level CGEvents (needs Accessibility). Pointer
/// coordinates are target pixels; `origin` and `scale` map them to global
/// display points, clamped to `bounds`. Buttons use rd's X numbering
/// (1 left, 2 middle, 3 right); scroll is hundredths of a line, or of a
/// point when precise, positive down and right. Every key and button it
/// pressed is released by `releaseAll()`. Not Sendable: one target actor
/// owns it.
public final class CGEventDesktopInput {
    private let origin: CGPoint
    private let scale: Double
    private let bounds: CGRect
    private let keyCodes = HidMacKeyCodeMap()
    private let source = CGEventSource(stateID: .hidSystemState)
    private var position: CGPoint
    private var buttons: Set<UInt8> = []
    private var keys: Set<HidUsage> = []

    /// - Parameters:
    ///   - origin: global display point of target pixel (0, 0).
    ///   - scale: target pixels per point.
    ///   - bounds: the target in global points; pointer events stay inside.
    public init(origin: CGPoint, scale: Double, bounds: CGRect) {
        self.origin = origin
        self.scale = max(0.1, scale)
        self.bounds = bounds
        position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    public func apply(_ event: RdInputEvent) {
        switch event {
        case .pointer(let x, let y):
            position = clamp(CGPoint(x: origin.x + Double(x) / scale, y: origin.y + Double(y) / scale))
            let (type, button) = moveType()
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button))
        case .button(let button, let down):
            let (type, cgButton) = buttonType(button, down: down)
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton)
            if button > 3 { event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button - 1)) }
            if down { buttons.insert(button) } else { buttons.remove(button) }
            post(event)
        case .scroll(let dx, let dy, let precise):
            let event = CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line, wheelCount: 2,
                                wheel1: Int32(-dy / 100), wheel2: Int32(-dx / 100), wheel3: 0)
            post(event)
        case .key(let usage, let down):
            let hid = HidUsage(rawValue: usage)
            guard let code = keyCodes.keyCode(for: hid) else { return }
            if down { keys.insert(hid) } else { keys.remove(hid) }
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags()
            post(event)
        case .text(let text):
            type(text)
        case .service:
            break
        }
    }

    /// Lifts every key and button this injector holds (session end, mode change).
    public func releaseAll() {
        for usage in keys { apply(.key(usage: usage.rawValue, down: false)) }
        for button in buttons { apply(.button(button: button, down: false)) }
    }

    private func type(_ text: String) {
        let units = Array(text.utf16)
        var start = 0
        // CGEvent carries at most 20 UTF-16 units of text per event.
        while start < units.count {
            let end = min(start + 20, units.count)
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
            start = end
        }
    }

    private func moveType() -> (CGEventType, CGMouseButton) {
        if buttons.contains(1) { return (.leftMouseDragged, .left) }
        if buttons.contains(3) { return (.rightMouseDragged, .right) }
        if !buttons.isEmpty { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func buttonType(_ button: UInt8, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case 1: (down ? .leftMouseDown : .leftMouseUp, .left)
        case 3: (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    private func flags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if keys.contains(.leftShift) || keys.contains(.rightShift) { flags.insert(.maskShift) }
        if keys.contains(.leftControl) || keys.contains(.rightControl) { flags.insert(.maskControl) }
        if keys.contains(.leftOption) || keys.contains(.rightOption) { flags.insert(.maskAlternate) }
        if keys.contains(.leftCommand) || keys.contains(.rightCommand) { flags.insert(.maskCommand) }
        return flags
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}
#endif
