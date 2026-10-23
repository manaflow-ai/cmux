import AppKit
import CmuxFoundation
import SwiftUI

/// What the welcome window's one prominent button does for this account.
enum CloudWelcomeNextStep: Equatable {
    case signIn
    case upgrade
    case enable
    /// The plan is not known yet (or could not be loaded): open the Cloud tab,
    /// whose own gate decides between Upgrade and Enable.
    case openCloud

    /// Stack Auth creates one personal team for a normal account. A free
    /// account gets shared-team access only when its accepted list contains an
    /// additional team.
    static func hasSharedTeamAccess(availableTeamCount: Int) -> Bool {
        availableTeamCount > 1
    }

    static func resolve(
        isAuthenticated: Bool,
        isPlanKnown: Bool,
        isPro: Bool,
        hasCloudTeamAccess: Bool = false
    ) -> CloudWelcomeNextStep {
        // Signed out reads like Free: Upgrade to Pro (the pricing page signs in).
        guard isAuthenticated else { return .upgrade }
        guard isPlanKnown else { return .openCloud }
        return isPro || hasCloudTeamAccess ? .enable : .upgrade
    }
}

/// "Cloud machines for your agents": shown once, on the first launch of a
/// release in the welcome campaign, for users who can use Cloud. A compact introduction above feature clips and the next step.
///
/// Takes plain values (no app objects) so the same view renders in the app and
/// in a standalone lab; ``CloudWelcomeWindowController`` feeds it the account.
struct CloudWelcomeView: View {
    let nextStep: CloudWelcomeNextStep
    let onNotNow: () -> Void
    let onNext: (CloudWelcomeNextStep) -> Void
    /// Whether the account has an accepted team in addition to its personal scope.
    var hasCloudTeamAccess = false
    /// Where each slide's clip lives (the lab points this at a folder).
    var mediaURL: (CloudWelcomeSlide) -> URL? = CloudWelcomeMediaCarousel.bundledMediaURL
    // Lab toggles while the slider is designed.
    var showsMedia = true
    var showsReasons = true
    var sliderAutoplays = true
    var sliderShowsFeatureList = true
    var sliderListUsesDots = false
    /// Launch card: the selected Headline preview ships by default.
    var posterHeadline: String? = CloudWelcomeView.headline
    /// Launch card: the user's New Cloud Machine shortcut for the Create row.
    var newMachineShortcut: String? = "⇧⌘Y"
    /// Launch card variations (debug comparisons): title in the poster band or
    /// under the clip, the icon in the band, a New badge, and a footer with
    /// Not Now beside the action.
    var posterShowsTitle = true
    var posterShowsIcon = true
    var showsNewBadge = false
    var footerHasNotNow = false
    @State private var isHoveringPrimary = false
    @State private var isHoveringNotNow = false

    static let windowWidth: CGFloat = 580
    nonisolated static let headline = String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents")
    /// The launch layout: the clip poster on top, the features under it.
    static let listWindowWidth: CGFloat = CloudWelcomeMediaCarousel.posterWidth

    var body: some View {
        let hasMedia = showsMedia && CloudWelcomeSlide.all.contains { mediaURL($0) != nil }
        if hasMedia && sliderShowsFeatureList {
            return AnyView(launchBody)
        }
        return AnyView(VStack(spacing: 0) {
            CloudWelcomeHeader()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 22)
            if hasMedia {
                CloudWelcomeMediaCarousel(slides: CloudWelcomeSlide.all, mediaURL: mediaURL, autoplays: sliderAutoplays, showsFeatureList: sliderShowsFeatureList, listUsesDots: sliderListUsesDots)
                    .padding(.bottom, 24)
            } else {
                CloudWelcomeHero()
            }
            panel(hasMedia: hasMedia)
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
        .frame(width: Self.windowWidth)
        .background(windowBackground)
        .accessibilityIdentifier("CloudWelcomeWindow"))
    }

    /// The campaign launch card: the clip poster (with the title in its band),
    /// the five features, then one full-width action with the plan line under
    /// it. The × in the corner (and Escape) is Not Now.
    private var launchBody: some View {
        VStack(spacing: 0) {
            CloudWelcomeMediaCarousel(
                slides: CloudWelcomeSlide.all,
                mediaURL: mediaURL,
                autoplays: sliderAutoplays,
                showsFeatureList: true,
                listUsesDots: false,
                posterHeadline: posterHeadline,
                newMachineShortcut: newMachineShortcut,
                posterShowsTitle: posterShowsTitle,
                posterShowsIcon: posterShowsIcon,
                showsNewBadge: showsNewBadge,
                cardWidth: launchCardWidth
            )
            if footerHasNotNow {
                launchFooterWithNotNow
            } else {
            VStack(spacing: 9) {
                Button {
                    onNext(nextStep)
                } label: {
                    Text(primaryLabel)
                        .cmuxFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor)
                                // Darkens a step under the pointer, like a native button.
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.black.opacity(isHoveringPrimary ? 0.14 : 0))
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHoveringPrimary = hovering }
                }
                // No Return shortcut: the window appears on its own at launch, and a
                // Return meant for the terminal must not enable Cloud or open pricing.
                .accessibilityIdentifier("CloudWelcomePrimaryButton")
                Text(noteLines.joined(separator: " "))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 20)
            }
        }
        .frame(width: launchCardWidth)
        .overlay(alignment: .topTrailing) {
            Button(action: onNotNow) {
                Image(systemName: "xmark")
                    .cmuxFont(size: 9, weight: .bold)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "common.notNow", defaultValue: "Not Now"))
            .accessibilityLabel(String(localized: "common.notNow", defaultValue: "Not Now"))
            .accessibilityIdentifier("CloudWelcomeNotNowButton")
            .padding(12)
        }
        // An opaque card (no glass): the same colour as the window behind it.
        .background(Color(nsColor: Self.launchCardColor))
        .accessibilityIdentifier("CloudWelcomeWindow")
    }

    /// The Not Now footer needs room for the plan line and two buttons on one row.
    private var launchCardWidth: CGFloat {
        footerHasNotNow ? 480 : Self.listWindowWidth
    }

    /// The plan line on the left, Not Now and the action on the right, under a hairline.
    private var launchFooterWithNotNow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(noteLines.joined(separator: " "))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Button(action: onNotNow) {
                    Text(String(localized: "common.notNow", defaultValue: "Not Now"))
                        .cmuxFont(size: 13, weight: .medium)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(isHoveringNotNow ? 0.16 : 0.1)))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHoveringNotNow = hovering }
                }
                Button {
                    onNext(nextStep)
                } label: {
                    Text(primaryLabel)
                        .cmuxFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(isHoveringPrimary ? 0.14 : 0)))
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHoveringPrimary = hovering }
                }
                .accessibilityIdentifier("CloudWelcomePrimaryButton")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .padding(.top, 14)
    }

    /// The launch card: a lifted near-black on dark, near-white on light.
    static var launchCardColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.11, alpha: 1)
                : NSColor(white: 0.98, alpha: 1)
        }
    }

    /// On macOS 26 the window hosts this view inside an NSGlassEffectView (the
    /// controller does that), so the glass is the window itself: it fills the
    /// window to its own corners and never lenses this content. SwiftUI's
    /// .glassEffect painted behind the content did both (a second rim inside the
    /// window edge, and a ghost of the title). Earlier macOS gets the window material.
    @ViewBuilder
    private var windowBackground: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            CloudWelcomeVisualEffect()
                .ignoresSafeArea()
        }
        #else
        CloudWelcomeVisualEffect()
            .ignoresSafeArea()
        #endif
    }

    private func panel(hasMedia: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsReasons && !hasMedia {
            VStack(alignment: .leading, spacing: 12) {
                CloudWelcomeReasonRow(
                    symbol: "terminal",
                    text: String(
                        localized: "cloud.enable.benefit.agents",
                        defaultValue: "Agents and terminals keep running after you close your laptop."
                    )
                )
                CloudWelcomeReasonRow(
                    symbol: "laptopcomputer",
                    text: String(
                        localized: "cloud.enable.benefit.reattach",
                        defaultValue: "Pick up where you left off from any Mac you sign in on."
                    )
                )
                CloudWelcomeReasonRow(
                    symbol: "person.2",
                    text: String(
                        localized: "cloud.enable.reason.team.detail",
                        defaultValue: "Invite teammates, and share any port with a private link."
                    )
                )
            }
            .padding(.bottom, 20)
            }
            Divider()
            footer
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(noteLines, id: \.self) { line in
                    Text(line)
                }
            }
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: onNotNow) {
                Text(String(localized: "common.notNow", defaultValue: "Not Now"))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("CloudWelcomeNotNowButton")
            Button {
                onNext(nextStep)
            } label: {
                Text(primaryLabel)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .environment(\.controlActiveState, .key)
            // No Return shortcut: the window appears on its own at launch, and a
            // Return meant for the terminal must not enable Cloud or open pricing.
            .accessibilityIdentifier("CloudWelcomePrimaryButton")
        }
    }

    private var primaryLabel: String {
        switch nextStep {
        case .signIn:
            return String(localized: "cloud.enable.signIn.action", defaultValue: "Sign In")
        case .upgrade:
            return String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro")
        case .enable:
            return String(localized: "cloud.enable.action", defaultValue: "Enable Cloud")
        case .openCloud:
            return String(localized: "cloud.welcome.setUp", defaultValue: "Set Up Cloud")
        }
    }

    private var noteLines: [String] {
        let available = String(
            localized: "cloud.welcome.note.available",
            defaultValue: "Cloud is available on cmux Pro and Max."
        )
        switch nextStep {
        case .enable:
            if hasCloudTeamAccess {
                return [String(
                    localized: "cloud.welcome.note.teamIncluded",
                    defaultValue: "Included through your team’s plan."
                )]
            }
            return [String(localized: "cloud.welcome.note.alreadyIncluded", defaultValue: "Already included in your plan.")]
        case .signIn, .upgrade, .openCloud:
            return [available]
        }
    }
}

private struct CloudWelcomeHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill")
                    .cmuxFont(size: 11, weight: .semibold)
                Text(String(localized: "cloud.welcome.title.eyebrow", defaultValue: "cmux cloud"))
                    .cmuxFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
            }
            Text(String(localized: "cloud.welcome.title", defaultValue: "Your work, wherever you go"))
                .cmuxFont(size: 30, weight: .bold)
                .tracking(-0.35)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The window material before macOS 26 (what the About window uses).
private struct CloudWelcomeVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct CloudWelcomeReasonRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .cmuxFont(size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .cmuxFont(size: 13)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
