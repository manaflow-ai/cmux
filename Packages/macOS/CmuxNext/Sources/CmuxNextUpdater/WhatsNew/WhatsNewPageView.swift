import CmuxNextDesign
public import SwiftUI

/// What the page asks the App to do. Every closure runs as the user.
public struct WhatsNewPageActions {
    public var tryIt: (WhatsNewDocument.TryIt) -> Void
    public var openDocs: (URL) -> Void
    public var openAllNotes: () -> Void
    /// Where a media path of a document from `origin` loads from.
    public var mediaURL: (String, WhatsNewDocument.Origin) -> URL?

    public init(tryIt: @escaping (WhatsNewDocument.TryIt) -> Void, openDocs: @escaping (URL) -> Void,
                openAllNotes: @escaping () -> Void, mediaURL: @escaping (String, WhatsNewDocument.Origin) -> URL?) {
        self.tryIt = tryIt
        self.openDocs = openDocs
        self.openAllNotes = openAllNotes
        self.mediaURL = mediaURL
    }
}

/// The What's New top page (WHATS-NEW-AFTER-UPDATE W1): every missed
/// version, newest first; per version its headline and entries grouped by
/// category, each with media (light or dark to match the window), a Try It
/// button and a docs link. Gray chrome only (no accent color).
public struct WhatsNewPageView: View {
    let content: WhatsNewPageContent
    let actions: WhatsNewPageActions

    public init(content: WhatsNewPageContent, actions: WhatsNewPageActions) {
        self.content = content
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space6 * 2) {
                Text(WhatsNewStrings.title)
                    .font(Font(Typography.title))
                    .foregroundStyle(Color(nsColor: Palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
                if content.isEmpty {
                    Text(WhatsNewStrings.empty)
                        .font(Font(Typography.subtitle))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                }
                ForEach(content.sections) { section in
                    WhatsNewSectionView(section: section, actions: actions)
                }
                Button(WhatsNewStrings.allNotes) { actions.openAllNotes() }
                    .buttonStyle(.plain)
                    .font(Font(Typography.caption))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .underline()
            }
            .padding(.horizontal, Metrics.space6 * 2)
            .padding(.vertical, Metrics.space6 * 2)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Color(nsColor: Palette.pageBackground))
        .tint(Color(nsColor: Palette.focusRing))
    }
}
