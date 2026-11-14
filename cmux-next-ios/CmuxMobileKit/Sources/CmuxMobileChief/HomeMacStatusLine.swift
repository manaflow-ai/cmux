#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The line over Home's kept rows while its Mac is not live: the Workspaces tab's line for an
/// offline or unreachable Mac (its glyph in the rows' gutter, "Mac · detail", Retry at the
/// trailing edge), so the two tabs say a dropped Mac the same way. Not a card.
struct HomeMacStatusLine: View {
    let status: HomeConnectionStatus
    let macName: String?
    let retry: () async -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledAvatar: CGFloat = 45
    /// The rows' avatar column (``MessagesRow``): the glyph centered in it, the text at the titles' x.
    private var avatarSize: CGFloat { min(max(scaledAvatar, 45), 64) }

    private var text: String {
        "\(macName ?? String(localized: "Your Mac")) · \(status.detail)"
    }

    private var canRetry: Bool { status.empty?.canRetry ?? true }

    var body: some View {
        Button {
            guard canRetry, !status.isRetrying else { return }
            theme.haptics.selection()
            Task { await retry() }
        } label: {
            HStack(spacing: 0) {
                Group {
                    if status.isRetrying {
                        CmuxSpinner().controlSize(.small)
                    } else {
                        Image(systemName: status.kind == .macOffline ? "moon.zzz" : "bolt.horizontal.circle")
                    }
                }
                // In the rows' avatar column, as Workspaces' glyph sits in its rows' gutter.
                .frame(width: avatarSize)
                .padding(.leading, 26)
                .padding(.trailing, 12)
                .accessibilityHidden(true)
                Text(verbatim: text)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Spacer(minLength: 8)
                if canRetry, !status.isRetrying {
                    Text("Retry")
                }
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canRetry || status.isRetrying)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityAddTraits(canRetry ? .isButton : [])
        .accessibilityHint(canRetry && !status.isRetrying ? Text("Tries to reach your Mac again") : Text(verbatim: ""))
        .accessibilityIdentifier("home.macStatus")
    }
}
#endif
