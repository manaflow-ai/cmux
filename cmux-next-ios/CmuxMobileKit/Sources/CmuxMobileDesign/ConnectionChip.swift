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
/// A link state the person can do nothing about says nothing for its first
/// ``QuietStatusGate/threshold`` (10 s, the shared bound in
/// `schemas/notice-timing/notice-timing.json`): the chip is laid out but drawn clear,
/// untappable and hidden from VoiceOver until it has lasted that long, so a blip, a
/// foreground reattach or a daemon handoff shows nothing and moves nothing. Past it,
/// it shows, carrying its Retry when the caller gave one. A caller that already held
/// the state for the bound passes `heldFor: .zero`.
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
    let retry: (@MainActor () async -> Void)?
    @State private var quiet: QuietStatusGate

    public init(_ content: Content, heldFor: Duration = QuietStatusGate.threshold,
                retry: (@MainActor () async -> Void)? = nil) {
        self.content = content
        self.retry = retry
        _quiet = State(initialValue: QuietStatusGate(delay: heldFor))
    }

    public var body: some View {
        chip
            .opacity(quiet.isShown ? 1 : 0)
            .allowsHitTesting(quiet.isShown)
            .accessibilityHidden(!quiet.isShown)
            .animation(.easeOut(duration: 0.2), value: quiet.isShown)
            .onAppear { quiet.update(down: true) }
            .onDisappear { quiet.update(down: false) }
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
    /// Held quiet for the same bound as the chip.
    struct SymbolOnly: View {
        let content: Content
        @State private var quiet: QuietStatusGate

        public init(_ content: Content, heldFor: Duration = QuietStatusGate.threshold) {
            self.content = content
            _quiet = State(initialValue: QuietStatusGate(delay: heldFor))
        }

        public var body: some View {
            symbol
                .opacity(quiet.isShown ? 1 : 0)
                .accessibilityHidden(!quiet.isShown)
                .animation(.easeOut(duration: 0.2), value: quiet.isShown)
                .onAppear { quiet.update(down: true) }
                .onDisappear { quiet.update(down: false) }
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
#endif
