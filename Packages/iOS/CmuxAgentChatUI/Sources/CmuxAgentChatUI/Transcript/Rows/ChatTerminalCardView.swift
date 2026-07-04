import CmuxAgentChat
import SwiftUI

/// A near-full-width terminal card: command header with run status, and the
/// captured output as a horizontally scrolling monospace block.
///
/// Long cards preview the head and tail of output at a stable row height.
public struct ChatTerminalCardView: View {
    private let capture: ChatTerminalCapture
    private let rowID: String

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatContentCache) private var contentCache

    private static let collapseThreshold = 6
    private static let collapsedHeadCount = 3
    private static let collapsedTailCount = 2

    /// Creates a terminal card.
    ///
    /// - Parameters:
    ///   - capture: The command-and-output payload.
    ///   - rowID: The row's stable identity, for cached output rendering.
    public init(
        capture: ChatTerminalCapture,
        rowID: String
    ) {
        self.capture = capture
        self.rowID = rowID
    }

    public var body: some View {
        let lines = outputLines
        VStack(spacing: 0) {
            header
            if !lines.isEmpty {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 0.5)
                outputBlock(lines: lines)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.terminalCardFill, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
    }

    /// Sanitized output split into display lines; empty when there is no
    /// output yet.
    private var outputLines: [String] {
        guard let output = capture.output, !output.isEmpty else { return [] }
        if let cache = contentCache {
            return cache.sanitizedLines(messageID: rowID, output: output)
        }
        let cleaned = ChatANSISanitizer().sanitized(output)
        return cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: "$")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.accent)
            Text(capture.command)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.terminalCardText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            trailingStatus
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// VoiceOver label for the header: the command plus its run outcome.
    private var headerAccessibilityLabel: String {
        if capture.isRunning {
            return String(
                localized: "chat.terminal.running.accessibility",
                defaultValue: "Command \(capture.command), running",
                bundle: .module
            )
        }
        if let exitCode = capture.exitCode {
            if exitCode == 0 {
                return String(
                    localized: "chat.terminal.succeeded.accessibility",
                    defaultValue: "Command \(capture.command), succeeded",
                    bundle: .module
                )
            }
            return String(
                localized: "chat.terminal.failed.accessibility",
                defaultValue: "Command \(capture.command), failed, exit code \(exitCode)",
                bundle: .module
            )
        }
        return String(
            localized: "chat.terminal.command.accessibility",
            defaultValue: "Command \(capture.command)",
            bundle: .module
        )
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if capture.isRunning {
            ProgressView()
                .controlSize(.mini)
        } else {
            if let exitCode = capture.exitCode {
                HStack(spacing: 3) {
                    Image(systemName: exitCode == 0 ? "checkmark" : "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                    if exitCode != 0 {
                        Text(verbatim: "\(exitCode)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
            if let duration = capture.durationSeconds {
                Text(verbatim: String(format: "%.1fs", duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func outputBlock(lines: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if lines.count > Self.collapseThreshold {
                    collapsedOutput(lines: lines)
                } else {
                    outputText(lines: lines)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func collapsedOutput(lines: [String]) -> some View {
        let hiddenCount = lines.count - Self.collapsedHeadCount - Self.collapsedTailCount
        outputText(lines: Array(lines.prefix(Self.collapsedHeadCount)))
        Text(
            String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(hiddenCount) more lines",
                bundle: .module
            )
        )
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        outputText(lines: Array(lines.suffix(Self.collapsedTailCount)))
            .opacity(0.55)
    }

    /// One verbatim monospace text block; lines are preserved as captured.
    private func outputText(lines: [String]) -> some View {
        Text(verbatim: lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.terminalCardText)
            .lineLimit(nil)
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
    }
}
