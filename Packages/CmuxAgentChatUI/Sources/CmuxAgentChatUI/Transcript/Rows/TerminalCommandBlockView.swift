import CmuxAgentChat
import SwiftUI

/// One row of a plain-terminal chat: a `❯` command line over its monospace
/// output and a run-status footer. Full-width, left-aligned, single column —
/// a log, not opposing bubbles — which is what visually distinguishes a
/// terminal session from an agent conversation in the shared chat surface.
///
/// A block that entered a full-screen program renders the
/// ``TerminalInteractiveCardView`` escape hatch instead of its raw screen.
public struct TerminalCommandBlockView: View {
    private let block: TerminalCommandBlock
    private let isExpanded: Bool
    private let onToggleExpanded: () -> Void
    private let onOpenTerminal: () -> Void

    @Environment(\.chatTheme) private var theme

    private static let collapseThreshold = 12
    private static let collapsedHeadCount = 6
    private static let collapsedTailCount = 3

    /// Creates a terminal command-block row.
    ///
    /// - Parameters:
    ///   - block: The parsed command/output unit.
    ///   - isExpanded: Whether long output is fully shown.
    ///   - onToggleExpanded: Toggles the long-output collapse.
    ///   - onOpenTerminal: Opens the raw terminal (escape hatch).
    public init(
        block: TerminalCommandBlock,
        isExpanded: Bool,
        onToggleExpanded: @escaping () -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.block = block
        self.isExpanded = isExpanded
        self.onToggleExpanded = onToggleExpanded
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        if block.isInteractive {
            TerminalInteractiveCardView(command: block.command, onOpenTerminal: onOpenTerminal)
        } else {
            commandBlock
        }
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            commandRow
            if !outputLines.isEmpty {
                outputBlock
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.leading, block.failed ? 8 : 0)
        .overlay(alignment: .leading) {
            // A red left rail makes failed commands scannable while flicking
            // through history.
            if block.failed {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red)
                    .frame(width: 2.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var commandRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "❯")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.accent)
            Text(block.command.isEmpty ? " " : block.command)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.terminalCardText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !isExpanded, outputLines.count > Self.collapseThreshold {
                    collapsedOutput
                } else {
                    outputText(outputLines)
                }
            }
        }
    }

    @ViewBuilder
    private var collapsedOutput: some View {
        let hidden = outputLines.count - Self.collapsedHeadCount - Self.collapsedTailCount
        outputText(Array(outputLines.prefix(Self.collapsedHeadCount)))
        Button(action: onToggleExpanded) {
            Text(
                String(
                    localized: "chat.terminal.more_lines",
                    defaultValue: "⋯ \(hidden) more lines",
                    bundle: .module
                )
            )
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.accent)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        outputText(Array(outputLines.suffix(Self.collapsedTailCount)))
            .opacity(0.55)
    }

    private func outputText(_ lines: [String]) -> some View {
        Text(verbatim: lines.joined(separator: "\n"))
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(theme.terminalCardText)
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var footer: some View {
        if block.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(
                    String(
                        localized: "chat.terminal.running", defaultValue: "running", bundle: .module
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else if let exitCode = block.exitCode {
            HStack(spacing: 4) {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(exitCode == 0 ? .green : .red)
                if exitCode != 0 {
                    Text(verbatim: "exit \(exitCode)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Output split into display lines (already ANSI/CR-cleaned by the parser).
    private var outputLines: [String] {
        guard !block.output.isEmpty else { return [] }
        return block.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var accessibilityLabel: String {
        if block.isRunning {
            return String(
                localized: "chat.terminal.running.accessibility",
                defaultValue: "Command \(block.command), running",
                bundle: .module
            )
        }
        if let exitCode = block.exitCode, exitCode != 0 {
            return String(
                localized: "chat.terminal.failed.accessibility",
                defaultValue: "Command \(block.command), failed, exit code \(exitCode)",
                bundle: .module
            )
        }
        return String(
            localized: "chat.terminal.succeeded.accessibility",
            defaultValue: "Command \(block.command), succeeded",
            bundle: .module
        )
    }
}

#if DEBUG
#Preview("Terminal log") {
    ScrollView {
        VStack(alignment: .leading, spacing: 4) {
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 0, command: "ls -la", output: "total 8\ndrwxr-xr-x  4 me  staff  128 Jun 12 .\n-rw-r--r--  1 me  staff   42 Jun 12 README.md",
                    exitCode: 0, isRunning: false
                ),
                isExpanded: false, onToggleExpanded: {}, onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 1, command: "npm run build", output: "compiling…", exitCode: nil, isRunning: true
                ),
                isExpanded: false, onToggleExpanded: {}, onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 2, command: "false && echo nope", output: "", exitCode: 1, isRunning: false
                ),
                isExpanded: false, onToggleExpanded: {}, onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 3, command: "vim notes.md", output: "", exitCode: nil, isRunning: true, isInteractive: true
                ),
                isExpanded: false, onToggleExpanded: {}, onOpenTerminal: {}
            )
        }
        .padding()
    }
}
#endif
