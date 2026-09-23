#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Density for the What's New page. `regular` is the HIG template look;
/// `compact` tightens fonts and spacing so the whole page still fits without
/// scrolling on the smallest iPhones (owner contract: standard type sizes
/// never scroll; only accessibility sizes may fall back to a scroll view).
enum MobileWhatsNewPageLayout {
    case regular
    case compact

    var topPadding: CGFloat {
        switch self {
        case .regular: 40
        case .compact: 32
        }
    }

    var headerSpacing: CGFloat {
        switch self {
        case .regular: 36
        case .compact: 18
        }
    }

    var titleFont: Font {
        switch self {
        case .regular: .largeTitle.bold()
        case .compact: .title2.bold()
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .regular: 28
        case .compact: 13
        }
    }

    var iconFont: Font {
        switch self {
        case .regular: .title2
        case .compact: .title3
        }
    }

    var iconWidth: CGFloat {
        switch self {
        case .regular: 40
        case .compact: 30
        }
    }

    var featureTitleFont: Font {
        switch self {
        case .regular: .headline
        case .compact: .subheadline.weight(.semibold)
        }
    }

    var detailFont: Font {
        switch self {
        case .regular: .subheadline
        case .compact: .footnote
        }
    }

    var noticeFont: Font {
        switch self {
        case .regular: .footnote
        case .compact: .caption
        }
    }

    var noticePadding: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 10
        }
    }

    var bottomPadding: CGFloat {
        switch self {
        case .regular: 24
        case .compact: 12
        }
    }
}

/// Picks the densest What's New layout that shows the whole page with no
/// scrolling. The scroll tier is the last-resort fallback: accessibility
/// type sizes and geometries where even compact cannot fit (short
/// landscape); clipping content is never acceptable, so the fallback is not
/// gated by type size. Portrait iPhones at standard type fit the compact
/// tier (verified down to the 375x667 iPhone SE).
struct MobileWhatsNewFittingPage: View {
    let page: MobileWhatsNewPage

    var body: some View {
        ViewThatFits(in: .vertical) {
            MobileWhatsNewContent(page: page, layout: .regular)
            MobileWhatsNewContent(page: page, layout: .compact)
            ScrollView {
                MobileWhatsNewContent(page: page, layout: .compact)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The shared What's New title + feature-row layout, HIG What's New template
/// shape: plain background, centered large title, accent symbol rows.
/// Announcements carry a tinted badge above the title so service news reads
/// differently from binary release notes.
struct MobileWhatsNewContent: View {
    let page: MobileWhatsNewPage
    var layout: MobileWhatsNewPageLayout = .regular

    var body: some View {
        switch page.body {
        case .pairingSetup:
            MobileWhatsNewPairingSetupContent(
                page: page,
                layout: layout
            )
        case .features:
            featureRowsContent
        case .web:
            EmptyView()
        }
    }

    private var featureRowsContent: some View {
        VStack(spacing: layout.headerSpacing) {
            VStack(spacing: 8) {
                if page.isAnnouncement {
                    MobileWhatsNewAnnouncementBadge()
                }
                Text(page.title)
                    .font(layout.titleFont)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, layout.topPadding)
            .padding(.horizontal, 32)
            if case .features(let features) = page.body {
                VStack(alignment: .leading, spacing: layout.rowSpacing) {
                    // Positional identity: remote feature rows carry no id
                    // and duplicate titles must not merge or drop rows.
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.symbol)
                                .font(layout.iconFont)
                                .foregroundStyle(.tint)
                                .frame(width: layout.iconWidth)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(layout.featureTitleFont)
                                Text(feature.detail)
                                    .font(layout.detailFont)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, page.footnote == nil ? layout.bottomPadding : 0)
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
                        .font(layout.noticeFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(layout.noticePadding)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .padding(.horizontal, 28)
                .padding(.bottom, layout.bottomPadding)
                .accessibilityIdentifier("MobileWhatsNewFootnote")
            }
        }
    }
}

/// A purpose-built release page for the Mac-side pairing gate. The screenshot
/// makes the required switch recognizable, while the compatibility block reads
/// the same policy that connection admission uses.
struct MobileWhatsNewPairingSetupContent: View {
    let page: MobileWhatsNewPage
    let layout: MobileWhatsNewPageLayout
    @Environment(MobileMacCompatCenter.self) private var macCompatCenter: MobileMacCompatCenter?

    private var compatibility: MobileWhatsNewMacCompatibility {
        MobileWhatsNewCatalog().macCompatibility(
            policy: macCompatCenter?.policy ?? .baked,
            iosVersion: AppVersionInfo.current().marketingVersion,
            buildType: MobileBuildType.current()
        )
    }

    var body: some View {
        VStack(spacing: layout.headerSpacing) {
            VStack(spacing: 10) {
                OnboardingBalancedText(
                    page.title,
                    role: layout == .regular ? .title : .title2,
                    alignment: .center,
                    maximumNumberOfLines: 2,
                    reservesMaximumLines: true
                )

                Text(L10n.string(
                    "mobile.pairingOptInUpdate.requirement",
                    defaultValue: "On your Mac, open Settings > Mobile and turn on Enable iOS pairing."
                ))
                .font(layout.detailFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, layout.topPadding)
            .padding(.horizontal, 28)

            settingsScreenshot
            accountRequirement
            compatibilitySection
        }
        .padding(.bottom, layout.bottomPadding)
        .accessibilityIdentifier("MobileWhatsNewPairingSetup")
    }

    private var settingsScreenshot: some View {
        screenshotImage
            .padding(.horizontal, 24)
    }

    private var screenshotImage: some View {
        Image("OnboardingPairingSettings", bundle: .module)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityLabel(L10n.string(
                "mobile.whatsNew.pairing.screenshotLabel",
                defaultValue: "cmux Mac Settings, Mobile section, showing Enable iOS pairing."
            ))
            .accessibilityIdentifier("MobileWhatsNewMacSettingsScreenshot")
    }

    private var accountRequirement: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(
                "mobile.onboarding.pairing.phoneLabel",
                defaultValue: "On this iPhone"
            ))
            .font(layout.featureTitleFont)
            .accessibilityIdentifier("MobileWhatsNewPhoneTitle")
            Text(L10n.string(
                "mobile.onboarding.pairing.phoneDetail",
                defaultValue: "Sign in to the same cmux account"
            ))
            .font(layout.detailFont)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileWhatsNewPhoneDetail")
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("MobileWhatsNewPairingRequirement")
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                L10n.string(
                    "mobile.whatsNew.pairing.compatibilityTitle",
                    defaultValue: "Mac version required"
                )
            )
            .font(layout.featureTitleFont)

            VStack(spacing: 8) {
                compatibilityRow(
                    title: L10n.string(
                        "mobile.whatsNew.pairing.stableLabel",
                        defaultValue: "Stable Mac"
                    ),
                    value: stableRequirement
                )
                compatibilityRow(
                    title: L10n.string(
                        "mobile.whatsNew.pairing.nightlyLabel",
                        defaultValue: "Nightly Mac"
                    ),
                    value: nightlyRequirement
                )
            }

            if MobileBuildType.current().usesInternalBuildVocabulary {
                Text(MobileWhatsNewCatalog().macUpdateDetail(
                    buildType: MobileBuildType.current(),
                    requiredVersion: compatibility.stableVersion
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.horizontal, 24)
        .accessibilityIdentifier("MobileWhatsNewCompatibility")
    }

    private func compatibilityRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospaced())
                .multilineTextAlignment(.trailing)
        }
    }

    private var stableRequirement: String {
        guard let version = compatibility.stableVersion else {
            return L10n.string(
                "mobile.whatsNew.pairing.noStableMinimum",
                defaultValue: "No stable minimum listed"
            )
        }
        return String(
            format: L10n.string(
                "mobile.whatsNew.pairing.macVersionFormat",
                defaultValue: "cmux %@ or later"
            ),
            version
        )
    }

    private var nightlyRequirement: String {
        guard let version = compatibility.nightlyVersion else {
            return L10n.string(
                "mobile.whatsNew.pairing.noNightlyMinimum",
                defaultValue: "No separate minimum"
            )
        }
        return String(
            format: L10n.string(
                "mobile.whatsNew.pairing.nightlyVersionFormat",
                defaultValue: "cmux NIGHTLY %@ or later"
            ),
            version
        )
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
