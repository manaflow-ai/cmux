#if os(iOS)
import CmuxScreenKit
import SwiftUI

/// One-tap Mac shortcuts under the session toolbar (Spotlight, Mission
/// Control, the app switcher, editing keys), sent as key chords. Pass your
/// own `shortcuts` to change the row.
public struct MacShortcutsBar: View {
    let session: ScreenSession
    let shortcuts: [Shortcut]

    public init(session: ScreenSession, shortcuts: [Shortcut] = MacShortcutsBar.standard) {
        self.session = session
        self.shortcuts = shortcuts
    }

    public struct Shortcut: Identifiable, Sendable {
        /// Also the button's title.
        public let id: String
        /// An SF Symbol.
        public let symbol: String
        public let modifiers: [VNCKeysym]
        public let key: VNCKeysym

        public init(_ title: String, symbol: String, modifiers: [VNCKeysym], key: VNCKeysym) {
            id = title
            self.symbol = symbol
            self.modifiers = modifiers
            self.key = key
        }
    }

    static func letter(_ character: Character) -> VNCKeysym { VNCKeysym(character: character) }

    /// Spotlight, Mission Control, App Windows, Switch App, Copy, Paste,
    /// Undo, Select All, New Tab, Close Window, Quit App, Screenshot, Force
    /// Quit, Lock Screen.
    public static let standard: [Shortcut] = [
        Shortcut("Spotlight", symbol: "magnifyingglass", modifiers: [.command], key: .space),
        Shortcut("Mission Control", symbol: "rectangle.3.group", modifiers: [.control], key: .up),
        Shortcut("App Windows", symbol: "macwindow.on.rectangle", modifiers: [.control], key: .down),
        Shortcut("Switch App", symbol: "square.stack.3d.up", modifiers: [.command], key: .tab),
        Shortcut("Copy", symbol: "doc.on.doc", modifiers: [.command], key: letter("c")),
        Shortcut("Paste", symbol: "doc.on.clipboard", modifiers: [.command], key: letter("v")),
        Shortcut("Undo", symbol: "arrow.uturn.backward", modifiers: [.command], key: letter("z")),
        Shortcut("Select All", symbol: "selection.pin.in.out", modifiers: [.command], key: letter("a")),
        Shortcut("New Tab", symbol: "plus.square.on.square", modifiers: [.command], key: letter("t")),
        Shortcut("Close Window", symbol: "xmark.square", modifiers: [.command], key: letter("w")),
        Shortcut("Quit App", symbol: "power", modifiers: [.command], key: letter("q")),
        Shortcut("Screenshot", symbol: "camera.viewfinder", modifiers: [.command, .shift], key: letter("4")),
        Shortcut("Force Quit", symbol: "exclamationmark.octagon", modifiers: [.command, .option], key: .escape),
        Shortcut("Lock Screen", symbol: "lock", modifiers: [.control, .command], key: letter("q")),
    ]

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        session.tap(shortcut.key, modifiers: shortcut.modifiers)
                    } label: {
                        Label(shortcut.id, systemImage: shortcut.symbol)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends the Mac shortcut")
                }
            }
            .padding(.horizontal, 10)
        }
    }
}
#endif
