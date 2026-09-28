import AppKit
import CmuxFoundation
import SwiftUI

// Drawing for terminal code block affordances. SwiftUI and CmuxFoundation
// only, so scripts/ui-lab can render it without an app build
// (scripts/ui-lab/harnesses/terminal-code-blocks.swift).

/// Localized copy for the code block affordances.
enum TerminalCodeBlockStrings {
    static var copy: String { String(localized: "terminal.codeBlock.copy", defaultValue: "Copy") }
    static var copied: String { String(localized: "terminal.codeBlock.copied", defaultValue: "Copied") }
    static var run: String { String(localized: "terminal.codeBlock.run", defaultValue: "Run") }
    static var copyHelp: String {
        String(localized: "terminal.codeBlock.copy.help", defaultValue: "Copy the block's exact text")
    }
    static var runHelp: String {
        String(
            localized: "terminal.codeBlock.run.help",
            defaultValue: "Open a new split with this command typed at the prompt. Nothing runs until you press Return."
        )
    }
    static var reviewTitle: String {
        String(localized: "terminal.codeBlock.review.title", defaultValue: "Open this command in a new split?")
    }
    static var reviewMessage: String {
        String(
            localized: "terminal.codeBlock.review.message",
            defaultValue: "cmux opens a new split in the same directory and types the command below at its prompt, or puts it on the clipboard if that shell can't take a multi-line paste safely. Nothing runs until you press Return there."
        )
    }
    static var reviewConfirm: String {
        String(localized: "terminal.codeBlock.review.confirm", defaultValue: "Open in New Split")
    }
    static var reviewCancel: String {
        String(localized: "terminal.codeBlock.review.cancel", defaultValue: "Cancel")
    }
    static var dismiss: String {
        String(localized: "terminal.codeBlock.dismiss", defaultValue: "Dismiss")
    }
    static var untitled: String {
        String(localized: "terminal.codeBlock.untitled", defaultValue: "Command")
    }
}

/// Shared visual constants.
enum TerminalCodeBlockStyle {
    static let cornerRadius: CGFloat = 7
    static let cardCornerRadius: CGFloat = 10
    static let cardWidth: CGFloat = 320
    static let previewLineLimit = 4
    static let monospace = Font.system(size: 11.5, design: .monospaced)

    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var stroke: Color { Color.primary.opacity(0.14) }
    static var codeWell: Color { Color.primary.opacity(0.06) }
}

/// A compact Copy / Run button pair.
struct TerminalCodeBlockActionButtons: View {
    let block: TerminalCodeBlock
    let onCopy: () -> Void
    let onRun: () -> Void
    /// Set by previews and ui-lab to show the confirmation state.
    var showsCopiedInitially = false

    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                onCopy()
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1400))
                    copied = false
                }
            } label: {
                // Both labels are laid out so the button keeps the wider
                // width and the overlay frame never clips "Copied".
                ZStack {
                    Label(TerminalCodeBlockStrings.copied, systemImage: "checkmark")
                        .opacity(isShowingCopied ? 1 : 0)
                    Label(TerminalCodeBlockStrings.copy, systemImage: "doc.on.doc")
                        .opacity(isShowingCopied ? 0 : 1)
                }
            }
            .buttonStyle(TerminalCodeBlockButtonStyle())
            .help(TerminalCodeBlockStrings.copyHelp)

            if block.isRunnable {
                Button(action: onRun) {
                    Label(TerminalCodeBlockStrings.run, systemImage: "play.fill")
                }
                .buttonStyle(TerminalCodeBlockButtonStyle())
                .help(TerminalCodeBlockStrings.runHelp)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11, weight: .medium))
    }

    private var isShowingCopied: Bool { copied || showsCopiedInitially }
}

/// The hover pill drawn at the top-right of a block on screen.
struct TerminalCodeBlockPill: View {
    let block: TerminalCodeBlock
    let onCopy: () -> Void
    let onRun: () -> Void
    var showsCopiedInitially = false

    var body: some View {
        TerminalCodeBlockActionButtons(
            block: block,
            onCopy: onCopy,
            onRun: onRun,
            showsCopiedInitially: showsCopiedInitially
        )
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: TerminalCodeBlockStyle.cornerRadius, style: .continuous)
                .fill(TerminalCodeBlockStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TerminalCodeBlockStyle.cornerRadius, style: .continuous)
                .strokeBorder(TerminalCodeBlockStyle.stroke)
        )
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .fixedSize()
    }
}

/// Cards for blocks a process offered with `cmux code-block`, newest first.
struct TerminalCodeBlockTray: View {
    let blocks: [TerminalCodeBlock]
    let onCopy: (TerminalCodeBlock) -> Void
    let onRun: (TerminalCodeBlock) -> Void
    let onDismiss: (TerminalCodeBlock) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(blocks) { block in
                TerminalCodeBlockCard(
                    block: block,
                    onCopy: { onCopy(block) },
                    onRun: { onRun(block) },
                    onDismiss: { onDismiss(block) }
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One offered block: label, a short preview, and its actions.
struct TerminalCodeBlockCard: View {
    let block: TerminalCodeBlock
    let onCopy: () -> Void
    let onRun: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: block.isRunnable ? "terminal" : "doc.plaintext")
                    .foregroundStyle(.secondary)
                Text(block.label ?? TerminalCodeBlockStrings.untitled)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let language = block.language {
                    Text(verbatim: language)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(TerminalCodeBlockStyle.codeWell))
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(TerminalCodeBlockButtonStyle())
                .help(TerminalCodeBlockStrings.dismiss)
                .accessibilityLabel(TerminalCodeBlockStrings.dismiss)
            }
            VStack(alignment: .leading, spacing: 1) {
                // One Text per line so a long line truncates instead of
                // wrapping into something that reads like two commands.
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(TerminalCodeBlockStyle.monospace)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(TerminalCodeBlockStyle.codeWell)
            )
            HStack {
                Spacer()
                TerminalCodeBlockActionButtons(block: block, onCopy: onCopy, onRun: onRun)
            }
        }
        .padding(10)
        .frame(minWidth: 0, idealWidth: TerminalCodeBlockStyle.cardWidth, maxWidth: TerminalCodeBlockStyle.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: TerminalCodeBlockStyle.cardCornerRadius, style: .continuous)
                .fill(TerminalCodeBlockStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TerminalCodeBlockStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(TerminalCodeBlockStyle.stroke)
        )
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }

    private var previewLines: [String] {
        let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > TerminalCodeBlockStyle.previewLineLimit else { return lines }
        return Array(lines.prefix(TerminalCodeBlockStyle.previewLineLimit - 1)) + ["…"]
    }
}

/// Shown before Run proceeds with a multi-line or long command: the whole
/// command, and an explicit confirm.
struct TerminalCodeBlockReviewView: View {
    let block: TerminalCodeBlock
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TerminalCodeBlockStrings.reviewTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(TerminalCodeBlockStrings.reviewMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Long lines wrap so no part of the command is out of view.
            ScrollView(.vertical) {
                Text(verbatim: block.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: codeHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(TerminalCodeBlockStyle.codeWell)
            )
            HStack {
                Spacer()
                Button(TerminalCodeBlockStrings.reviewCancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(TerminalCodeBlockStrings.reviewConfirm, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 460)
    }

    /// Fits short commands, scrolls long ones. Counts wrapped rows: about
    /// 55 monospaced characters fit the 460 pt popover.
    private var codeHeight: CGFloat {
        let lineHeight: CGFloat = 15
        let columns = 55
        let rows = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + columns - 1) / columns) }
        return min(240, CGFloat(max(1, rows)) * lineHeight + 18)
    }
}

/// Borderless small button with a hover fill, matching the find bar's buttons.
struct TerminalCodeBlockButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.09 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
