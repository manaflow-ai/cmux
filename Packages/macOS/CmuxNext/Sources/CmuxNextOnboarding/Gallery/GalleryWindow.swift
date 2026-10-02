import AppKit

/// Gallery keys (also sent over the debug socket).
public enum GalleryKey: Equatable, Sendable {
    case previousVariant, nextVariant, previousScreen, nextScreen, jump(Int), pick, compare, appearance, runFlow, copy, close

    /// Names for `debug.onboarding gallery_key` (`left`, `right`, `up`, `down`, `1`…`9`, `p`, `space`, `t`, `return`, `copy`, `escape`).
    public init?(name: String) {
        switch name {
        case "left": self = .previousVariant
        case "right": self = .nextVariant
        case "up": self = .previousScreen
        case "down": self = .nextScreen
        case "p": self = .pick
        case "space": self = .compare
        case "t": self = .appearance
        case "return": self = .runFlow
        case "copy": self = .copy
        case "escape": self = .close
        default:
            guard let number = Int(name), (1...9).contains(number) else { return nil }
            self = .jump(number - 1)
        }
    }
}

/// Routes the gallery keys unless a text field (the note) is editing, or a
/// flow running in the stage owns them (only Escape leaves the flow).
final class GalleryWindow: NSWindow {
    var onKey: ((GalleryKey) -> Bool)?
    var flowRunning = false

    override func keyDown(with event: NSEvent) {
        guard !(firstResponder is NSTextView), let key = Self.key(for: event), !flowRunning || key == .close, onKey?(key) == true else {
            return super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { _ = onKey?(.close) }

    static func key(for event: NSEvent) -> GalleryKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "c" { return .copy }
        guard flags.subtracting([.numericPad, .function]).isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .previousVariant
        case 124: return .nextVariant
        case 126: return .previousScreen
        case 125: return .nextScreen
        case 49: return .compare
        case 36, 76: return .runFlow
        case 53: return .close
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": return .pick
        case "t": return .appearance
        case let digit? where digit.count == 1 && "123456789".contains(digit): return .jump(Int(digit)! - 1)
        default: return nil
        }
    }
}
