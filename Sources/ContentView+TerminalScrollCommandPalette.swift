import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static let terminalScrollToBottomCommandId = "palette.terminalScrollToBottom"

    /// "Scroll to Bottom" for the focused terminal. The keyboard path is
    /// Ghostty's own `scroll_to_bottom` binding (Cmd+End by default).
    static func commandPaletteTerminalScrollContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: terminalScrollToBottomCommandId,
                title: { _ in String(localized: "command.terminalScrollToBottom.title", defaultValue: "Scroll to Bottom") },
                subtitle: subtitle,
                keywords: [
                    "terminal", "scroll", "bottom", "jump", "end", "latest", "newest",
                    "follow", "output", "scrollback", "tail", "live", "down",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            ),
        ]
    }

    func registerTerminalScrollCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.terminalScrollToBottomCommandId) {
            if !tabManager.scrollFocusedTerminalToBottom() {
                NSSound.beep()
            }
        }
    }
}
