import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A jump target on a Settings page: the scroll id search and deep links
/// scroll to, and the tint that lights it up after a jump. The tint's
/// removal is animated (or not, under Reduce Motion) by whoever clears
/// `SettingsWindowModel.highlighted` (`SettingsDetailView`).
struct SettingsAnchorView<Content: View>: View {
    let id: String
    let isHighlighted: Bool
    /// Between the wrapped views (cards: the page's spacing; rows: none).
    var spacing: CGFloat = Metrics.space6
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .background(SettingsStyle.tint.opacity(isHighlighted ? SettingsStyle.highlightOpacity : 0),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .id(id)
    }
}

/// A search result's title: a link that opens the result on its page.
struct SettingsJumpTitle: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space2) {
                Text(title).underline(hovering)
                Image(systemName: "arrow.forward").font(SettingsStyle.caption).foregroundStyle(SettingsStyle.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(SettingsWindowStrings.showSetting)
    }
}

/// The one page's header offsets, by section. A plain reference held in
/// `@State`, not observed: the scroll-spy writes it on every scroll step
/// without re-running the page's body.
final class SettingsSpyOffsets {
    var offsets: [SettingsSection: CGFloat] = [:]
    /// Set by a jump or sidebar click, which picked the section itself;
    /// cleared when the user scrolls `releaseDistance` away from `heldAt`.
    var heldByJump = false
    /// The scroll offset the jump settled at (nil until it has).
    var heldAt: CGFloat?
    var contentOffset: CGFloat = 0
    static let releaseDistance: CGFloat = 4
}
