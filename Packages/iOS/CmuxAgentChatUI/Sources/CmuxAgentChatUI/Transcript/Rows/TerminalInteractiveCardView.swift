import SwiftUI

/// Shown in place of a command's output when it entered a full-screen
/// program (vim, htop, less, an ncurses app). The chat can't sensibly render
/// an alt-screen TUI as a message, so it offers the raw terminal instead.
public struct TerminalInteractiveCardView: View {
    private let command: String
    private let onOpenTerminal: () -> Void

    @Environment(\.chatTheme) private var theme

    /// Creates the interactive-program card.
    ///
    /// - Parameters:
    ///   - command: The command that took over the screen (for the label).
    ///   - onOpenTerminal: Opens the raw terminal surface.
    public init(command: String, onOpenTerminal: @escaping () -> Void) {
        self.command = command
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: "❯")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.accent)
                Text(command.isEmpty ? " " : command)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.terminalCardText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        localized: "chat.terminal.interactive",
                        defaultValue: "Interactive program — open the full terminal",
                        bundle: .module
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onOpenTerminal) {
                Text(
                    String(
                        localized: "chat.terminal.open_in_terminal",
                        defaultValue: "Open in terminal",
                        bundle: .module
                    )
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TerminalInteractiveOpenButton")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.terminalCardFill, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                localized: "chat.terminal.interactive.accessibility",
                defaultValue: "\(command) is an interactive program. Open the full terminal.",
                bundle: .module
            )
        )
    }
}
