#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI

/// Another agent's message in the transcript (AgentIncoming): at the left with the agent's rows,
/// never the person's bubble at the right. The sender's chip, "agent" so it never reads as the
/// person's own words, the time, and the message as Markdown, without the envelope it came in
/// (the row's menu copies it as sent). Several that went in as one turn draw as a compact stack,
/// one line per message, each opening in place.
struct AgentIncomingCard: View {
    let incoming: AgentIncoming
    let at: Date
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if incoming.messages.count == 1 {
                MarkdownView(markdown: incoming.messages[0].text, margin: 0)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(incoming.messages.enumerated()), id: \.offset) { index, message in
                        if index > 0 { Divider() }
                        stacked(message, index: index)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.cmuxMobileBubble.opacity(0.55), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(incoming.messages.count == 1 ? incoming.senders : "\(incoming.messages.count) messages from other agents")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("agent")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
            Spacer(minLength: 4)
            Text(at, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func stacked(_ message: AgentIncoming.Message, index: Int) -> some View {
        let isOpen = open.contains(index)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cmuxMobileSmooth) {
                    if isOpen { open.remove(index) } else { open.insert(index) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(message.sender)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if !isOpen {
                        Text(Self.firstLine(message.text))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Closes the message" : "Opens the message")
            if isOpen {
                MarkdownView(markdown: message.text, margin: 0)
            }
        }
        .padding(.vertical, 8)
    }

    /// The message's first line of text, its Markdown marks left out.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|>\s?|[-*+]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
    }
}
#endif
