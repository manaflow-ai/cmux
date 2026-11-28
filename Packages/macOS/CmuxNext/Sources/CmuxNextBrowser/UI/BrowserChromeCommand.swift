public import AppKit

/// Commands the browser chrome can perform. The App layer registers these
/// as palette actions and menu items and calls `BrowserChromeView.perform`,
/// so every entrypoint shares one path.
public nonisolated enum BrowserChromeCommand: String, Hashable, Sendable, CaseIterable {
    case focusAddressBar
    case findInPage
    case findNext
    case findPrevious
    case reload
    case stop
    case goBack
    case goForward
    case zoomIn
    case zoomOut
    case resetZoom
    case showDevTools

    /// Default key equivalent, used by the chrome when
    /// `BrowserChromeView.handlesDefaultShortcuts` is true.
    public var defaultShortcut: (key: String, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .focusAddressBar: ("l", .command)
        case .findInPage: ("f", .command)
        case .findNext: ("g", .command)
        case .findPrevious: ("g", [.command, .shift])
        case .reload: ("r", .command)
        case .stop: (".", .command)
        case .goBack: ("[", .command)
        case .goForward: ("]", .command)
        case .zoomIn: ("=", .command)
        case .zoomOut: ("-", .command)
        case .resetZoom: ("0", .command)
        case .showDevTools: ("i", [.command, .option])
        }
    }

    /// The command bound to `event` by default, if any.
    public static func matching(_ event: NSEvent) -> BrowserChromeCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if key == "+", modifiers.contains(.command) { return .zoomIn }
        return allCases.first { command in
            let shortcut = command.defaultShortcut
            return shortcut.key == key && shortcut.modifiers == modifiers
        }
    }
}
