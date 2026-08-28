#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The shared What's New title + feature-row layout, HIG What's New template
/// shape: plain background, centered large title, accent symbol rows.
/// Announcements carry a tinted badge above the title so service news reads
/// differently from binary release notes.
struct MobileWhatsNewContent: View {
    let page: MobileWhatsNewPage

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 8) {
                if page.isAnnouncement {
                    MobileWhatsNewAnnouncementBadge()
                }
                Text(page.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 56)
            .padding(.horizontal, 32)
            if case .features(let features) = page.body {
                VStack(alignment: .leading, spacing: 28) {
                    // Positional identity: remote feature rows carry no id
                    // and duplicate titles must not merge or drop rows.
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, page.footnote == nil ? 24 : 0)
            }
            if let footnote = page.footnote {
                // A compact tinted notice, not plain fine print: owner
                // feedback was that secondary-style text gets missed, and
                // BETA users need the revert path. Still ambient (no alert,
                // HIG) and visually below the feature rows.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .accessibilityIdentifier("MobileWhatsNewFootnote")
            }
        }
    }
}

/// Small tinted marker distinguishing remote announcements.
struct MobileWhatsNewAnnouncementBadge: View {
    var body: some View {
        Text(L10n.string(
            "mobile.whatsNew.announcementBadge",
            defaultValue: "Announcement"
        ))
        .font(.subheadline.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("MobileWhatsNewAnnouncementBadge")
    }
}
#endif
