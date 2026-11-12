import Foundation
#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit
#endif

/// A Chief subagent's first message (optchat-chief `prompt::subagent_blocks`): the Chief's view,
/// `<chat>` … `</chat>`, then `Your task:` and the task. The transcript shows the view as one
/// collapsed line and only the task as the bubble; the session keeps the whole text (the agent
/// read it all). The Mac's pane does the same (`webviews/.../conversation/chiefEnvelope.ts`).
struct ChiefEnvelope: Equatable, Sendable {
    /// The view as the agent got it, `<chat>` to `</chat>`.
    var context: String
    /// Its lines, without the `<chat>` markers or blank lines.
    var lines: Int
    /// The task itself, after the `Your task:` label.
    var task: String

    private static let open = "<chat>"
    private static let close = "\n</chat>"
    private static let taskLabel = "Your task:"

    /// The envelope of `text`, or nil when it is not one: it starts with the view's `<chat>`
    /// marker and `Your task:` follows its `</chat>` (only whitespace between), as on the Mac.
    init?(_ text: String) {
        guard text.hasPrefix(Self.open), let close = text.range(of: Self.close) else { return nil }
        let rest = text[close.upperBound...]
        guard let start = rest.firstIndex(where: { !$0.isWhitespace }), rest[start...].hasPrefix(Self.taskLabel) else { return nil }
        context = String(text[..<close.upperBound])
        lines = context.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed != Self.open && trimmed != "</chat>"
        }.count
        task = rest[start...].dropFirst(Self.taskLabel.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(iOS)
/// The Chief's view over a subagent's first prompt, collapsed to one line ("Context from the
/// Chief (N lines)", the Mac's `transcript.chiefContext`); opened, the view in a bounded scroller
/// with Copy. Trailing, over the bubble it belongs to.
struct ChiefContextRow: View {
    let context: String
    let lines: Int
    /// The transcript's key for the person's choice (its rows are reused cells).
    let id: String
    @State private var localOpen = false
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold

    private var key: String { "chiefContext-\(id)" }
    private var open: Bool { disclosures?.isOpen(key) ?? localOpen }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    toggleDisclosure(holdFold, key: key, in: disclosures) {
                        if let disclosures { disclosures.set(key, !open) } else { localOpen.toggle() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text("Context from the Chief (\(lines) lines)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                Button {
                    UIPasteboard.general.string = context
                } label: {
                    Image(systemName: "doc.on.doc").font(.footnote).foregroundStyle(.tertiary)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy context")
            }
            .padding(.vertical, -10)
            if open {
                ScrollView {
                    Text(context)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 320)
                .background(Color.cmuxMobileBubble.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.disclosureReveal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
#endif
