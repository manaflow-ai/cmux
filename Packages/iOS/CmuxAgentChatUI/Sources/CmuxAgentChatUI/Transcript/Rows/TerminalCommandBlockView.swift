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
    private let onOpenTerminal: () -> Void

    @Environment(\.chatTheme) private var theme

    private static let collapseThreshold = 12
    private static let collapsedHeadCount = 6
    private static let collapsedTailCount = 3
    private static let maxLineLength = 4000

    /// Creates a terminal command-block row.
    ///
    /// - Parameters:
    ///   - block: The parsed command/output unit.
    ///   - onOpenTerminal: Opens the raw terminal (escape hatch).
    public init(
        block: TerminalCommandBlock,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.block = block
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
        // Split the output once per render; outputLines was a computed property
        // read 5+ times per body pass (each a full re-split of growing output).
        let lines = outputLines
        return VStack(alignment: .leading, spacing: 3) {
            commandRow
            if !lines.isEmpty {
                outputBlock(lines)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        // Reserve the rail gutter on every row so command text stays aligned
        // whether or not the command failed (no cross-row horizontal shift).
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            // A red left rail makes failed commands scannable while flicking
            // through history; it sits in the reserved gutter.
            if block.failed {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red)
                    .frame(width: 2.5)
            }
        }
        .accessibilityIdentifier("TerminalCommandBlock-\(block.id)")
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

    @ViewBuilder
    private func outputBlock(_ lines: [String]) -> some View {
        if lines.count > Self.collapseThreshold {
            collapsedOutput(lines)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                outputText(lines)
            }
        }
    }

    @ViewBuilder
    private func collapsedOutput(_ lines: [String]) -> some View {
        let hidden = lines.count - Self.collapsedHeadCount - Self.collapsedTailCount
        ScrollView(.horizontal, showsIndicators: false) {
            outputText(Array(lines.prefix(Self.collapsedHeadCount)))
        }
        Text(
            String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(hidden) more lines",
                bundle: .module
            )
        )
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .frame(minHeight: 28, alignment: .leading)
        ScrollView(.horizontal, showsIndicators: false) {
            outputText(Array(lines.suffix(Self.collapsedTailCount)))
                .opacity(0.55)
        }
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
    /// Pathologically long single lines are capped so one 50k-column line
    /// can't force an unbounded-width Text layout on every render.
    private var outputLines: [String] {
        guard !block.output.isEmpty else { return [] }
        return block.output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.count > Self.maxLineLength
                ? String(line.prefix(Self.maxLineLength)) + "…"
                : String(line)
        }
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
                onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 1, command: "npm run build", output: "compiling…", exitCode: nil, isRunning: true
                ),
                onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 2, command: "false && echo nope", output: "", exitCode: 1, isRunning: false
                ),
                onOpenTerminal: {}
            )
            TerminalCommandBlockView(
                block: TerminalCommandBlock(
                    id: 3, command: "vim notes.md", output: "", exitCode: nil, isRunning: true, isInteractive: true
                ),
                onOpenTerminal: {}
            )
        }
        .padding()
    }
}
#endif
