#if os(iOS)
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A connection state as a small glass chip: a spinner or symbol and one or
/// two words ("Reconnecting", "Mac offline"), never a sentence. It floats over
/// the content (place it with `.overlay`, never in a stack) so showing or
/// hiding it moves nothing (Leo, 2026-11-21: "these connection indicators you
/// can just put a small unobtrusive thing somewhere without needing to block
/// any content ... toast type thing ... as a symbol or short thing, not a
/// sentence. stop layout shifting"). The full sentence is its accessibility
/// label. With `retry`, the chip is the Retry button.
///
/// A link state says nothing until the link has been down for
/// ``QuietStatusGate/threshold`` (10 s, the shared bound in
/// `schemas/notice-timing/notice-timing.json`; cmuxterm-hq
/// `docs/handbook/connection-state-with-no-action-or-bound.md`). Until then the chip is
/// laid out but drawn clear, untappable and hidden from VoiceOver, so a blip, a
/// foreground reattach or a daemon handoff shows nothing and moves nothing. Past it, it
/// shows, carrying its Retry when the caller gave one. The wait counts from `downSince`,
/// when the link dropped (the caller's record, ``nextDownSince(_:down:now:)``), not from
/// when this view appeared: a list re-render or a sheet over it does not restart it, and a
/// change of state while still down (Reconnecting to Mac offline) keeps it. A caller that
/// already held the state for the bound passes `downSince: nil`, and the chip shows at once.
public struct ConnectionChip: View {
    /// Every link state a chip can show, each with its one word pair and one symbol, so a state
    /// reads the same on every surface (the Home list, Workspaces, agent chat, the browser, the
    /// terminal). The only place a chip's word or symbol is chosen.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case connecting, reconnecting, updating
        /// The phone has no network.
        case offline
        /// The phone is online, the Mac is not.
        case macOffline
        /// The link failed for another reason (the Mac answered, the session did not).
        case cantReach

        public var word: String {
            switch self {
            case .connecting: String(localized: "Connecting")
            case .reconnecting: String(localized: "Reconnecting")
            case .updating: String(localized: "Updating")
            case .offline: String(localized: "Offline")
            case .macOffline: String(localized: "Mac offline")
            case .cantReach: String(localized: "Can't reach")
            }
        }

        /// An SF Symbol; nil shows a spinner (still trying).
        public var symbol: String? {
            switch self {
            case .connecting, .reconnecting, .updating: nil
            case .offline: "wifi.slash"
            case .macOffline: "moon.zzz"
            case .cantReach: "exclamationmark.triangle"
            }
        }
    }

    public struct Content: Sendable, Hashable {
        public var kind: Kind
        /// The sentence VoiceOver reads.
        public var sentence: String
        /// One or two words.
        public var word: String { kind.word }
        /// An SF Symbol; nil shows a spinner (still trying).
        public var symbol: String? { kind.symbol }

        public init(_ kind: Kind, sentence: String) {
            self.kind = kind
            self.sentence = sentence
        }
    }

    let content: Content
    let downSince: Date?
    let retry: (@MainActor () async -> Void)?
    @State private var quiet = QuietStatusGate()

    public init(_ content: Content, downSince: Date?, retry: (@MainActor () async -> Void)? = nil) {
        self.content = content
        self.downSince = downSince
        self.retry = retry
    }

    public var body: some View {
        let shown = quiet.isShown || Self.alreadyDownFor(downSince, now: Date()) >= quiet.delay
        chip
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .animation(.easeOut(duration: 0.2), value: shown)
            .modifier(QuietSince(quiet: quiet, downSince: downSince))
    }

    /// How long the link has been down at `now`; a nil `downSince` (the caller held it)
    /// counts as the whole bound already.
    /// The down time to pass before the caller has recorded its drop (the first frame, before
    /// its `onChange` runs): a fixed instant, so a re-render does not restart the wait, that
    /// counts as a drop that has only just happened.
    public static let justDropped = Date.distantFuture

    public static func alreadyDownFor(_ downSince: Date?, now: Date) -> Duration {
        guard let downSince else { return QuietStatusGate.threshold }
        return .milliseconds(Int64(max(0, now.timeIntervalSince(downSince)) * 1000))
    }

    /// A caller's record of when its link dropped: kept while it stays down (whatever the
    /// state says), set at the first down, cleared when it is back.
    public static func nextDownSince(_ since: Date?, down: Bool, now: Date) -> Date? {
        down ? (since ?? now) : nil
    }

    private var chip: some View {
        Group {
            if let retry {
                Button { Task { await retry() } } label: { label(retrying: true) }
                    .buttonStyle(.cmuxPressFill)
                    .accessibilityHint(Text(verbatim: RetryButton.defaultTitle))
                    .accessibilityIdentifier("connection.chip.retry")
            } else {
                label(retrying: false)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content.sentence))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("connection.chip")
    }

    private func label(retrying: Bool) -> some View {
        HStack(spacing: 5) {
            if let symbol = content.symbol {
                Image(systemName: symbol).imageScale(.small)
            } else {
                CmuxSpinner().controlSize(.mini)
            }
            Text(verbatim: content.word).lineLimit(1)
            if retrying {
                Image(systemName: "arrow.clockwise").imageScale(.small)
            }
        }
        .font(theme.type.meta.weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .foregroundStyle(theme.colors.label2)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .glassEffect(.regular, in: .capsule)
    }
}

public extension ConnectionChip {
    /// The chip as its symbol alone (a spinner while still trying), for a corner where even two
    /// words are too many. The words are its VoiceOver label with the sentence.
    /// Held quiet the same way as the chip, from the same `downSince`.
    struct SymbolOnly: View {
        let content: Content
        let downSince: Date?
        @State private var quiet = QuietStatusGate()

        public init(_ content: Content, downSince: Date?) {
            self.content = content
            self.downSince = downSince
        }

        public var body: some View {
            let shown = quiet.isShown || ConnectionChip.alreadyDownFor(downSince, now: Date()) >= quiet.delay
            symbol
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(!shown)
                .animation(.easeOut(duration: 0.2), value: shown)
                .modifier(QuietSince(quiet: quiet, downSince: downSince))
        }

        private var symbol: some View {
            Group {
                if let symbol = content.symbol {
                    Image(systemName: symbol).imageScale(.small)
                } else {
                    CmuxSpinner().controlSize(.mini)
                }
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(width: 30, height: 26)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: content.sentence))
            .accessibilityIdentifier("connection.chip")
        }
    }
}
/// Drives a chip's gate from its link's down time: on appear (and when `downSince` moves) it
/// waits what is left of the bound; on disappear it stops.
private struct QuietSince: ViewModifier {
    let quiet: QuietStatusGate
    let downSince: Date?

    func body(content: Content) -> some View {
        content
            .task(id: downSince) {
                quiet.update(down: false)
                quiet.update(down: true, alreadyDownFor: ConnectionChip.alreadyDownFor(downSince, now: Date()))
            }
            .onDisappear { quiet.update(down: false) }
    }
}
#endif
