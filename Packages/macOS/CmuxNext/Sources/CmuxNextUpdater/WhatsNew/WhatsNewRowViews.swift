import CmuxNextDesign
import SwiftUI

/// One version's section of the What's New page and its entry rows.
struct WhatsNewSectionView: View {
    let section: WhatsNewPageContent.Section
    let actions: WhatsNewPageActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space6) {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text(verbatim: "\(section.title) · \(section.date)")
                    .font(Font(Typography.caption))
                    .foregroundStyle(Color(nsColor: Palette.textTertiary))
                Text(section.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: Metrics.space4) {
                    Text(group.title)
                        .font(Font(Typography.header))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        WhatsNewRowView(row: row, origin: section.origin, actions: actions)
                    }
                }
            }
            Rectangle()
                .fill(Color(nsColor: Palette.separator))
                .frame(height: Metrics.dividerThickness)
        }
    }
}

struct WhatsNewRowView: View {
    let row: WhatsNewPageContent.Row
    let origin: WhatsNewDocument.Origin
    let actions: WhatsNewPageActions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            if let media = row.media, let url = actions.mediaURL(colorScheme == .dark ? media.dark : media.light, origin) {
                WhatsNewMediaView(url: url, isVideo: media.isVideo, alt: row.mediaAlt ?? row.title)
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.textPrimary))
                if let audience = row.audience {
                    Text(audience)
                        .font(Font(Typography.caption))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .padding(.horizontal, Metrics.space2)
                        .background(Capsule().fill(Color(nsColor: Palette.badgeFill)))
                }
            }
            Text(row.summary)
                .font(Font(Typography.subtitle))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if row.tryIt != nil || row.docs != nil {
                HStack(spacing: Metrics.space4) {
                    if let tryIt = row.tryIt {
                        Button(WhatsNewStrings.tryIt) { actions.tryIt(tryIt) }
                            .buttonStyle(.glass)
                            .font(Font(Typography.bodyEmphasized))
                    }
                    if let docs = row.docs {
                        Button(WhatsNewStrings.learnMore) { actions.openDocs(docs) }
                            .buttonStyle(.plain)
                            .font(Font(Typography.body))
                            .foregroundStyle(Color(nsColor: Palette.textSecondary))
                            .underline()
                    }
                }
                .padding(.top, Metrics.space1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whatsNew.entry.\(row.id)")
    }
}
