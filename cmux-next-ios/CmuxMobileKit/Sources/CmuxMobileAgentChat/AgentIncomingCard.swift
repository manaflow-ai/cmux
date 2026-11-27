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
    /// The transcript's key for whether a single message is open (`ChatDisclosures`).
    var disclosureKey: String?
    @State private var open: Set<Int> = []
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var localOpen = false
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold

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
            SelectableText(chiefText(message.text))
                .selectionMenu { _ in messageActions }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color(uiColor: .systemBlue), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("From Chief \(name): \(message.text)"))
        .accessibilityIdentifier("agent-chat.chief-bubble")
    }

    private func chiefText(_ source: String) -> NSAttributedString {
        let styles = NativeTextStyles(category: UIContentSizeCategory(typeSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return NativeMarkdownLayout.inlineText(source, font: styles.font(.body), color: .white,
                                               styles: styles, paragraph: paragraph, codeBackground: false)
    }

    private var messageActions: [UIMenuElement] {
        var rows: [UIMenuElement] = [
            SelectionMenu.action("Copy Message", "doc.on.doc") { UIPasteboard.general.string = incoming.text },
            SelectionMenu.action("Select Text", "selection.pin.in.out") { ChatSelectText.present(incoming.text) },
            SelectionMenu.action("Copy as Sent", "envelope") { UIPasteboard.general.string = incoming.raw },
        ]
        if let id = incoming.messageID {
            rows.append(UIAction(title: String(localized: "Copy Message ID \(id)"), image: UIImage(systemName: "number")) { _ in
                UIPasteboard.general.string = id
            })
        }
        return [UIMenu(title: AgentTurn.menuTimestamp(at), options: .displayInline, children: rows)]
    }

    @ViewBuilder private var disclosureMenu: some View {
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
            header.contextMenu { disclosureMenu }
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            if incoming.messages.count == 1 {
                if singleOpen {
                    MarkdownView(markdown: incoming.messages[0].text, margin: 0)
                        .transition(.disclosureReveal)
                }
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
        .cmuxMobileContentSurface(.card, in: .rect(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionMenu { _ in messageActions }
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
            .buttonStyle(.cmuxPressLine)
            .accessibilityHint(allOpen ? "Closes every message" : "Opens every message")
        } else {
            // One message starts closed: its sender's line and its first line, muted; a tap opens the
            // whole message in place, as the Mac's received line does (Leo, 2026-11-17: "collapse the
            // agent messages that come in by default ... rn they're just all expanded and it's kinda
            // undreadable").
            Button {
                toggleDisclosure(holdFold, key: disclosureKey, in: disclosures) {
                    if let disclosureKey, let disclosures { disclosures.set(disclosureKey, !singleOpen) } else { localOpen.toggle() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    headerLine(chevron: singleOpen)
                    if !singleOpen {
                        Text(Self.firstLine(incoming.messages.first?.text ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.cmuxPressLine)
            .accessibilityValue(singleOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(singleOpen ? "Closes the message" : "Opens the message")
            .accessibilityIdentifier("agent-chat.incoming-line")
        }
    }

    /// The transcript's disclosure key for a single message's row.
    static func key(_ rowID: String) -> String { "incoming-\(rowID)" }

    /// Whether a single message shows in full: the transcript's disclosure by `disclosureKey` (its
    /// rows are reused cells), else this view's own.
    private var singleOpen: Bool {
        disclosureKey.flatMap { disclosures?.isOpen($0) } ?? localOpen
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
            .buttonStyle(.cmuxPressFill)
            .contextMenu { disclosureMenu }
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
            .cmuxMobileContentSurface(.inset, in: Capsule())
    }
}
#endif
