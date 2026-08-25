#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Settings > What's New: every page this device may currently show, newest
/// first (announcements, then remote-visible binary entries), so release
/// notices stay findable after their one-time sheet was dismissed.
///
/// The observable center is read ONCE here above the List boundary and rows
/// receive plain values, per the SwiftUI list-boundary rule (issue #2586).
struct MobileWhatsNewListView: View {
    @Environment(MobileWhatsNewCenter.self) private var center: MobileWhatsNewCenter?

    var body: some View {
        // Without a center (previews, alternate hosts) the archive falls
        // back to the binary catalog, matching the never-fetched policy.
        let pages = center?.archivePages ?? MobileWhatsNewCatalog.entries
        let allowedHosts = center?.allowedWebHosts ?? []
        List {
            ForEach(pages, id: \.listID) { page in
                MobileWhatsNewArchiveRow(page: page, allowedHosts: allowedHosts)
            }
        }
        .navigationTitle(L10n.string(
            "mobile.settings.whatsNew",
            defaultValue: "What's New"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileWhatsNewList")
    }
}

/// One archive row plus its pushed detail. Holds only plain values.
private struct MobileWhatsNewArchiveRow: View {
    let page: MobileWhatsNewPage
    let allowedHosts: Set<String>

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                if page.isAnnouncement {
                    Text(L10n.string(
                        "mobile.whatsNew.announcementBadge",
                        defaultValue: "Announcement"
                    ))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                } else if let releaseLabel = page.releaseLabel {
                    Text(releaseLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("MobileWhatsNewEntry-\(page.id)")
    }

    @ViewBuilder
    private var destination: some View {
        switch page.body {
        case .features:
            ScrollView {
                MobileWhatsNewContent(page: page)
            }
            .background(PlatformPalette.systemBackground)
            .navigationBarTitleDisplayMode(.inline)
        case .web(let url):
            MobileWhatsNewWebView(url: url, allowedHosts: allowedHosts)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
