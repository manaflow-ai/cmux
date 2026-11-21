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
public struct ConnectionChip: View {
    public struct Content: Sendable, Hashable {
        /// One or two words.
        public var word: String
        /// An SF Symbol; nil shows a spinner (still trying).
        public var symbol: String?
        /// The sentence VoiceOver reads.
        public var sentence: String

        public init(word: String, symbol: String?, sentence: String) {
            self.word = word
            self.symbol = symbol
            self.sentence = sentence
        }
    }

    let content: Content
    let retry: (@MainActor () async -> Void)?

    public init(_ content: Content, retry: (@MainActor () async -> Void)? = nil) {
        self.content = content
        self.retry = retry
    }

    public var body: some View {
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
#endif
