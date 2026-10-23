import CoreGraphics
import Foundation

/// The keys a phone keyboard lacks, on the bar above it in a streamed browser tab, and
/// what each sends to the Mac's page (`cmux.rb/1` key events).
public enum StreamedBrowserKey: String, CaseIterable, Sendable {
    case escape, tab, left, up, down, right, selectAll, copy, cut, undo

    /// The bar's label: an SF Symbol, or a short text.
    public var symbol: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        case .selectAll: "selection.pin.in.out"
        case .copy: "doc.on.doc"
        case .cut: "scissors"
        case .undo: "arrow.uturn.backward"
        }
    }

    public var title: String {
        switch self {
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .left: String(localized: "Left Arrow")
        case .up: String(localized: "Up Arrow")
        case .down: String(localized: "Down Arrow")
        case .right: String(localized: "Right Arrow")
        case .selectAll: String(localized: "Select All")
        case .copy: String(localized: "Copy")
        case .cut: String(localized: "Cut")
        case .undo: String(localized: "Undo")
        }
    }

    /// The key down and up the Mac's page gets.
    public func events(_ wire: RemoteBrowserWire) -> [Data] {
        let (code, key, text, modifiers, commands): (String, String, String, RemoteBrowserWire.Modifiers, [String]) =
            switch self {
            case .escape: ("Escape", "Escape", "", [], [])
            case .tab: ("Tab", "Tab", "\t", [], [])
            case .left: ("ArrowLeft", "ArrowLeft", "", [], [])
            case .up: ("ArrowUp", "ArrowUp", "", [], [])
            case .down: ("ArrowDown", "ArrowDown", "", [], [])
            case .right: ("ArrowRight", "ArrowRight", "", [], [])
            case .selectAll: ("KeyA", "a", "", .command, ["SelectAll"])
            case .copy: ("KeyC", "c", "", .command, ["Copy"])
            case .cut: ("KeyX", "x", "", .command, ["Cut"])
            case .undo: ("KeyZ", "z", "", .command, ["Undo"])
            }
        return [wire.key(code, key: key, text: text, down: true, modifiers: modifiers, editCommands: commands),
                wire.key(code, key: key, text: text, down: false, modifiers: modifiers)]
    }

    /// What the software keyboard's own keys send (`UIKeyInput.insertText`): Return and
    /// Tab as keys, anything else as committed text (emoji, dictation, other scripts).
    public static func typed(_ text: String, wire: RemoteBrowserWire) -> [Data] {
        switch text {
        case "\n", "\r": [wire.key("Enter", key: "Enter", text: "\r", down: true), wire.key("Enter", key: "Enter", text: "\r", down: false)]
        case "\t": tab.events(wire)
        case "": []
        default: [wire.commit(text)]
        }
    }

    /// How much of a page of `page` (in window coordinates) the keyboard at
    /// `keyboard` covers: the page lays out in what is left, above the keyboard.
    public static func covered(page: CGRect, keyboard: CGRect?) -> CGFloat {
        guard let keyboard, !keyboard.isEmpty, keyboard.minY < page.maxY else { return 0 }
        return min(page.height, page.maxY - max(keyboard.minY, page.minY))
    }
}
