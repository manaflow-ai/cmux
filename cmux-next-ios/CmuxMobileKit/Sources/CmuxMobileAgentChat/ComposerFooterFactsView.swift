#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The session's facts in the composer's controls row (RFD 0130, the phone's form of the Mac's
/// `composer-footer-facts`): in `pulse`, a counter per live fact (subagents running, prompts
/// queued), glyph and number in a fixed slot, nothing at zero; in `door`, a faint info mark. Either
/// opens the Session card, every fact acpmux sent in its order. Off draws nothing.
struct ComposerFooterFactsView: View {
    let facts: AgentFooterFacts
    let mode: ComposerFooterFactsMode
    @State private var showsCard = false

    var body: some View {
        if mode != .off, !facts.isEmpty {
            Button { showsCard = true } label: {
                HStack(spacing: 6) {
                    if mode == .pulse, !facts.live.isEmpty {
                        ForEach(facts.live, id: \.kind) { fact in
                            HStack(spacing: 2) {
                                Image(systemName: fact.symbol).imageScale(.small)
                                // A fixed slot ("9+" past nine): a count fading in moves nothing.
                                Text(fact.countLabel)
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .frame(minWidth: 14, alignment: .leading)
                                    .contentTransition(.numericText(value: Double(fact.count ?? 0)))
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(fact.label)
                            .accessibilityValue(fact.value(now: .now) ?? "")
                        }
                    } else {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(Text("mobile.agentChat.footerFacts.session", bundle: .module))
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: 32, minHeight: 44)
                .contentShape(.rect)
                .animation(.cmuxMobileSmooth.unlessReduceMotion, value: facts.live)
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityIdentifier("chat.composer.footerFacts")
            .popover(isPresented: $showsCard) {
                ComposerSessionCard(facts: facts)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The Session card: one row per fact acpmux sent, in its order; a fact with nothing to say is
/// left out. The running turn's time moves once a second while the card is open.
struct ComposerSessionCard: View {
    let facts: AgentFooterFacts

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("mobile.agentChat.footerFacts.session", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(facts.facts, id: \.kind) { fact in
                    if let value = fact.value(now: context.date) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: fact.symbol)
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(fact.label).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(value)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // The folder's whole path, for a long-press or VoiceOver.
                                .help(fact.kind == .folder ? (fact.text ?? value) : value)
                                .textSelection(.enabled)
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
        .accessibilityIdentifier("chat.composer.sessionCard")
    }
}
#endif
