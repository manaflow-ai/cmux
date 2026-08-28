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
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
