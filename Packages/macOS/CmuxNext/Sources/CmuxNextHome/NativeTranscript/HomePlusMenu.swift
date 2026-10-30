import AppKit
import UniformTypeIdentifiers

/// One row of the Chief composer's + menu. The agent chat's + menu (webviews acpmux
/// `Composer.tsx`) has Attach files or images, Mention a file or folder (@), Search files,
/// Commands (/) and Plan; the Chief's composer has no mentions, slash commands or plan mode yet,
/// so it has the attach row plus its own Clipboard section. A new row is a case here, a place in
/// ``HomePlusMenuModel/sections(clipboard:)`` and a branch in the view's `perform`.
nonisolated enum HomePlusMenuItem: Hashable, Sendable {
    /// Attach Files or Images…: the message box's file picker (files only: Home attaches no folders).
    case attachFiles
    /// A recent copy: text goes in at the caret, a picture becomes an attachment.
    case clipboard(HomeClipboardEntry)
}

/// What the + menu shows, as values (tests read it; ``HomePlusMenu`` draws it).
nonisolated struct HomePlusMenuModel: Equatable, Sendable {
    /// Groups, each drawn after a separator; the clipboard group has a section header.
    let sections: [[HomePlusMenuItem]]

    /// Attach first, then the clipboard's rows (newest first) when there are any.
    static func sections(clipboard: [HomeClipboardEntry]) -> HomePlusMenuModel {
        var sections: [[HomePlusMenuItem]] = [[.attachFiles]]
        if !clipboard.isEmpty { sections.append(clipboard.map { .clipboard($0) }) }
        return HomePlusMenuModel(sections: sections)
    }

    /// A text row's title: the text on one line (runs of white space and line breaks become one
    /// space), cut to `limit` characters with an ellipsis.
    static func snippet(_ text: String, limit: Int = 48) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The + menu as an `NSMenu` above the + button: native, opens in the click's own turn, and
/// keyboard-navigable like any menu.
@MainActor
enum HomePlusMenu {
    /// The menu for `model`; `thumbnail` gives a picture row's image (nil: a picture glyph), and
    /// `perform` runs the chosen row after the menu closes.
    static func make(_ model: HomePlusMenuModel, thumbnail: (HomeClipboardEntry) -> NSImage?,
                     perform: @escaping (HomePlusMenuItem) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in model.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if section.contains(where: { if case .clipboard = $0 { true } else { false } }) {
                menu.addItem(.sectionHeader(title: HomeStrings.plusMenuClipboard))
            }
            for item in section { menu.addItem(row(item, thumbnail: thumbnail, perform: perform)) }
        }
        return menu
    }

    /// Opens `menu` with its bottom-left corner just above `anchor` (AppKit moves it below when
    /// there is no room above).
    static func popUp(_ menu: NSMenu, above anchor: NSView) {
        let gap: CGFloat = 4
        let bounds = anchor.bounds
        let height = menu.size.height
        let y = anchor.isFlipped ? bounds.minY - gap - height : bounds.maxY + gap + height
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: y), in: anchor)
    }

    private static func row(_ item: HomePlusMenuItem, thumbnail: (HomeClipboardEntry) -> NSImage?,
                            perform: @escaping (HomePlusMenuItem) -> Void) -> NSMenuItem {
        let row = NSMenuItem(title: "", action: #selector(HomePlusMenuTarget.run), keyEquivalent: "")
        let target = HomePlusMenuTarget { perform(item) }
        row.target = target
        row.representedObject = target // the item holds its target (`target` is weak)
        switch item {
        case .attachFiles:
            row.title = HomeStrings.plusMenuAttachFiles
            row.image = symbol("paperclip", HomeStrings.plusMenuAttachFiles)
        case .clipboard(let entry):
            switch entry.content {
            case .text(let text):
                row.title = HomePlusMenuModel.snippet(text)
                row.toolTip = String(text.prefix(400))
                row.image = symbol("text.alignleft", row.title)
            case .image(_, let type):
                row.title = UTType(type)?.localizedDescription ?? HomeStrings.plusMenuImage
                row.image = thumbnail(entry) ?? symbol("photo", row.title)
            }
        }
        row.setAccessibilityLabel(row.title)
        return row
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}

/// A menu row's action as a closure.
@MainActor
final class HomePlusMenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension HomeStrings {
    static var plusMenuAttachFiles: String {
        String(localized: "home.plusMenu.attachFiles", defaultValue: "Attach Files or Images…", bundle: .module)
    }
    static var plusMenuClipboard: String { String(localized: "home.plusMenu.clipboard", defaultValue: "Clipboard", bundle: .module) }
    static var plusMenuImage: String { String(localized: "home.plusMenu.image", defaultValue: "Image", bundle: .module) }
}
