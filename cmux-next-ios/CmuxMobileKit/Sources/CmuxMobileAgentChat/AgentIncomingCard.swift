#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// Another agent's message in the transcript (AgentIncoming): at the left with the agent's rows,
/// never the person's bubble at the right. The sender's chip, "agent" so it never reads as the
/// person's own words, the time, and the message as Markdown, without the envelope it came in
/// (the row's menu copies it as sent). Several that went in as one turn draw as a compact stack,
/// one line per message, each opening in place.
struct AgentIncomingCard: View {
    let incoming: AgentIncoming
    /// The images and files the prompt carried, as the person's bubble draws them.
    var attachments: [AgentAttachment] = []
    let at: Date
    @State private var open: Set<Int> = []

    var body: some View {
        if incoming.chief != nil, let message = incoming.messages.first {
            chiefBubble(message)
        } else {
            card
        }
    }

    /// A message a Chief's turn sent this chat (acpmux `fromChief`), as the person asked (CMUX-51: "if
    /// sent from chief, make it a blue bubble (not from me)"): a blue bubble at the right, under the
    /// Chief's own name and a "Chief" tag, so it never reads as the person's grey bubble. Its sender
    /// is said in words too (the line and the accessibility label), not by colour alone.
    private func chiefBubble(_ message: AgentIncoming.Message) -> some View {
        let name = message.sender
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .systemBlue))
                    .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                AgentIncomingChip(label: "Chief")
                if incoming.edited { AgentIncomingChip(label: "edited") }
                Text(at, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            Text(Self.inlineMarkdown(message.text))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color(uiColor: .systemBlue), in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu { menu }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("From Chief \(name): \(message.text)"))
        .accessibilityIdentifier("agent-chat.chief-bubble")
    }

    /// The message's inline Markdown (bold, code, links), its line breaks kept; as written when it
    /// does not read.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder private var menu: some View {
        Section(AgentTurn.menuTimestamp(at)) {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = incoming.text }
            Button("Select Text", systemImage: "selection.pin.in.out") { ChatSelectText.present(incoming.text) }
            // The prompt the agent got, envelope and all.
            Button("Copy as Sent", systemImage: "envelope") { UIPasteboard.general.string = incoming.raw }
            if let id = incoming.messageID {
                Button("Copy Message ID \(id)", systemImage: "number") { UIPasteboard.general.string = id }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
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
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 16, style: .continuous))
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    /// The harness a sender's icon draws: the card's, when one sender sent every message.
    private func harness(for message: AgentIncoming.Message) -> String? {
        incoming.oneSenderKey == message.toneKey ? incoming.harness : nil
    }

    /// A card of several messages opens and closes all of them from its header, so every message can
    /// be read from the top line (Leo, 2026-11-05: "we don't seem to be able to click it at the top
    /// level, which is no bueno. Like all of these things, we need to be able to see them here").
    @ViewBuilder private var header: some View {
        if incoming.messages.count > 1 {
            let allOpen = open.count == incoming.messages.count
            Button {
                withAnimation(.cmuxMobileSmooth.unlessReduceMotion) {
                    open = allOpen ? [] : Set(incoming.messages.indices)
                }
            } label: {
                headerLine(chevron: allOpen).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(allOpen ? "Closes every message" : "Opens every message")
        } else {
            headerLine(chevron: nil)
        }
    }

    private func headerLine(chevron open: Bool?) -> some View {
        HStack(spacing: 6) {
            // One sender, however many messages: its family's mark and its own badge, in the tone of
            // its session id (the Mac's), else its name.
            let one = incoming.oneSenderKey.flatMap { _ in incoming.messages.first }
            AgentSenderIcon(harness: one.flatMap(harness(for:)), identity: one?.toneKey ?? "messages", assignedTone: one?.tone, size: 16)
            Group {
                if incoming.messages.count != 1 {
                    Text("\(incoming.messages.count) messages")
                } else if incoming.unverified, incoming.senders.isEmpty {
                    Text("Unverified sender")
                } else {
                    Text(incoming.senders)
                }
            }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            // acpmux could not verify who sent it (Leo, 2026-11-05: "why is it sending it as if it
            // were me?"): never the person's.
            AgentIncomingChip(label: incoming.unverified ? "unverified" : "agent")
            if incoming.edited { AgentIncomingChip(label: "edited") }
            Spacer(minLength: 4)
            Text(at, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let open {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
    }

    private func stacked(_ message: AgentIncoming.Message, index: Int) -> some View {
        let isOpen = open.contains(index)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cmuxMobileSmooth.unlessReduceMotion) {
                    if isOpen { open.remove(index) } else { open.insert(index) }
                }
            } label: {
                HStack(spacing: 6) {
                    AgentSenderIcon(harness: harness(for: message), identity: message.toneKey, assignedTone: message.tone, size: 14)
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

/// The header's small capsule ("agent", "unverified", "edited"). Its own view, never a helper
/// method named like a `View` modifier: a `tag(_:)` helper here lost overload resolution to
/// SwiftUI's `View.tag(_:)` (a `String` literal beats a `LocalizedStringKey` one), so the header
/// drew the whole card again inside itself, without end, and the transcript crashed with a stack
/// overflow on the first agent message it laid out (TestFlight 20261110000821, 2026-11-09). The
/// Chief's bubble kept two such `tag("…")` calls after the helper was gone, which compiled the same
/// way and crashed the chat when it scrolled up to a Chief's message (AgentHistoryScrollUITests).
struct AgentIncomingChip: View {
    let label: LocalizedStringKey

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}
#endif
