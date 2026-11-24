// RFD 0130, piece 1: the phone composer's status dot, its live counters and its card. Leo,
// 2026-11-22: "some sort of status dot that fades in and when you hover or click into it
// (presumably a click in you can do a click out ...) and just have that be able to give you
// rundowns of various statuses." A phone has no hover (RFD 0128 "Touch"): a tap pins the card, a
// tap outside closes it. acpmux decides what it says (`AgentComposerStatus`); this view only draws.
// The web pane's own is webviews/src/agent-session/acpmux/ComposerStatusDot.tsx.
import CmuxMobileDesign
import SwiftUI

/// The composer-footer-facts experiment's arms, the web pane's (`composerFooterFacts.experiment.ts`)
/// less its desktop-only `strip`: `off` draws nothing (the composer as it shipped), `pulse` the dot
/// with its live counters beside it and the Session section in its card, `door` the dot and the
/// card without the counters.
public enum ComposerFooterFactsArm: String, CaseIterable, Sendable {
    case off, pulse, door

    public static let defaultsKey = CmuxMobilePreferences.Key.composerFooterFacts
    public static let defaultArm: Self = .off

    /// The stored arm; an unknown value reads as the default.
    public init(stored: String) { self = Self(rawValue: stored) ?? Self.defaultArm }
}

/// The dot (tinted by the worst shown item), the live counters (`pulse`) and, on a tap, the card
/// with the Status list and the Session section. Draws nothing while the arm is off or acpmux has
/// nothing to say, so it never takes room in the composer's row for nothing.
struct ComposerStatusDot: View {
    let status: AgentComposerStatus?
    let arm: ComposerFooterFactsArm
    /// A fixed clock (previews); nil follows the real one.
    var fixedNow: Date?
    /// Opens with the card pinned (previews).
    var startsPinned = false
    @State private var pinned = false

    var body: some View {
        if arm != .off, let status {
            TimelineView(.explicit(wakes(status))) { context in
                content(status, now: fixedNow ?? context.date)
            }
            .onAppear { if startsPinned { pinned = true } }
        }
    }

    /// Now, and each moment an item comes due (`showAt`): the dot's only timer.
    private func wakes(_ status: AgentComposerStatus) -> [Date] {
        let now = Date.now
        return [now] + status.items.compactMap(\.showAt).filter { $0 > now }.sorted()
    }

    @ViewBuilder
    private func content(_ status: AgentComposerStatus, now: Date) -> some View {
        let items = status.shownItems(at: now)
        let worst = items.map(\.level).max()
        let facts = status.facts.filter { $0.value(at: now) != nil }
        if worst != nil || !facts.isEmpty {
            HStack(spacing: 0) {
                Button { pinned.toggle() } label: {
                    Circle()
                        .fill(Self.tone(worst))
                        .frame(width: 7, height: 7)
                        .frame(width: 28, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(items.first?.text ?? Self.detailsWords)
                .accessibilityIdentifier("chat.composer.statusDot")
                if arm == .pulse { counters(status) }
            }
            .transition(.opacity)
            .popover(isPresented: $pinned, arrowEdge: .bottom) {
                ComposerStatusCard(status: status, items: items, fixedNow: fixedNow)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func counters(_ status: AgentComposerStatus) -> some View {
        ForEach(Self.counterKinds, id: \.kind) { counter in
            if let count = status.liveCount(counter.kind) {
                Button { pinned.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: counter.symbol).font(.caption2)
                        Text(verbatim: AgentComposerStatus.counterText(count))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .contentTransition(.numericText(value: Double(count)))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(counter.words(count))
            }
        }
    }

    private struct Counter {
        let kind: AgentComposerStatus.Fact.Kind
        let symbol: String
        let words: (Int) -> String
    }

    private static let counterKinds: [Counter] = [
        Counter(kind: .subagents, symbol: "person.2") { count in
            String(localized: "mobile.agentChat.composerStatus.subagentsCount", defaultValue: "Subagents running: \(count)", bundle: .module)
        },
        Counter(kind: .queued, symbol: "list.bullet") { count in
            String(localized: "mobile.agentChat.composerStatus.queuedCount", defaultValue: "Prompts queued: \(count)", bundle: .module)
        },
    ]

    static var detailsWords: String {
        String(localized: "mobile.agentChat.composerStatus.details", defaultValue: "Session details", bundle: .module)
    }

    /// The web dot's tones: muted at rest and for info, warning for attention, danger for a problem.
    static func tone(_ level: AgentComposerStatus.Item.Level?) -> Color {
        switch level {
        case .problem: .cmuxMobileDanger
        case .attention: .cmuxMobileWarning
        case .info, nil: .secondary
        }
    }
}

/// The dot's card: the Status list (the shown items, worst first) and the Session section (the
/// facts with something to say), each headed only when both show.
private struct ComposerStatusCard: View {
    let status: AgentComposerStatus
    let items: [AgentComposerStatus.Item]
    let fixedNow: Date?

    var body: some View {
        let ticks = fixedNow == nil && status.facts.contains { $0.kind == .turn && $0.since != nil }
        TimelineView(.periodic(from: .now, by: ticks ? 1 : 3600)) { context in
            card(now: fixedNow ?? context.date)
        }
    }

    private func card(now: Date) -> some View {
        let facts = status.facts.compactMap { fact in fact.value(at: now).map { (fact, $0) } }
        let both = !items.isEmpty && !facts.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if both { heading(String(localized: "mobile.agentChat.composerStatus.title", defaultValue: "Status", bundle: .module)) }
            ForEach(items, id: \.kind) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(ComposerStatusDot.tone(item.level)).frame(width: 6, height: 6)
                    Text(verbatim: item.text ?? "").font(.subheadline)
                    Spacer(minLength: 8)
                    if let since = item.since {
                        Text(since, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if both { heading(String(localized: "mobile.agentChat.composerStatus.session", defaultValue: "Session", bundle: .module)).padding(.top, 4) }
            if !facts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(facts, id: \.0.kind) { fact, value in
                        GridRow {
                            Text(verbatim: fact.label).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: value).font(.subheadline.monospacedDigit()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.statusCard")
    }

    private func heading(_ words: String) -> some View {
        Text(verbatim: words).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

#if DEBUG
enum ComposerStatusPreviewData {
    static let now = Date(timeIntervalSince1970: 1_795_500_000)
    static let status = AgentComposerStatus(
        items: [
            .init(kind: "rateLimited", level: .attention, words: "status.rateLimited.until",
                  until: now.addingTimeInterval(1800)),
            .init(kind: "machineLink", level: .info, words: "status.machineLink.reconnecting",
                  subject: "mini-3", since: now.addingTimeInterval(-40)),
        ],
        facts: [
            .init(kind: .machine, text: "mini-3"),
            .init(kind: .folder, text: "/Users/leo/Projects/cmux"),
            .init(kind: .branch, text: "lane/composer-status-dot"),
            .init(kind: .harness, text: "Claude Code"),
            .init(kind: .model, text: "Opus"),
            .init(kind: .context, fraction: 0.42),
            .init(kind: .turn, since: now.addingTimeInterval(-95)),
            .init(kind: .subagents, count: 3, live: true),
            .init(kind: .queued, count: 12, live: true),
        ])
}

private struct ComposerStatusPreviewRow: View {
    let title: String
    let arm: ComposerFooterFactsArm
    var pinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(verbatim: "Reply to Claude").foregroundStyle(.tertiary)
                Spacer()
                ComposerStatusDot(status: ComposerStatusPreviewData.status, arm: arm,
                                  fixedNow: ComposerStatusPreviewData.now, startsPinned: pinned)
                Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        }
    }
}

#Preview("Composer status: off, pulse, door") {
    VStack(spacing: 24) {
        ComposerStatusPreviewRow(title: "off (default: nothing drawn)", arm: .off)
        ComposerStatusPreviewRow(title: "pulse (dot + live counters)", arm: .pulse)
        ComposerStatusPreviewRow(title: "door (dot only)", arm: .door)
    }
    .padding()
}

#Preview("Composer status: pulse, card pinned") {
    ComposerStatusPreviewRow(title: "pulse, tapped", arm: .pulse, pinned: true).padding()
}

#Preview("Composer status: door, card pinned") {
    ComposerStatusPreviewRow(title: "door, tapped", arm: .door, pinned: true).padding()
}
#endif
