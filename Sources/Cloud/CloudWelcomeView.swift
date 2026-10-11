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

    static func resolve(isAuthenticated: Bool, isPlanKnown: Bool, isPro: Bool) -> CloudWelcomeNextStep {
        guard isAuthenticated else { return .signIn }
        guard isPlanKnown else { return .openCloud }
        return isPro ? .enable : .upgrade
    }
}

/// "Your work, wherever you go": shown once on the 0.65.1 launch for users who
/// can use Cloud. A compact introduction above feature clips and the next step.
///
/// Takes plain values (no app objects) so the same view renders in the app and
/// in a standalone lab; ``CloudWelcomeWindowController`` feeds it the account.
struct CloudWelcomeView: View {
    let nextStep: CloudWelcomeNextStep
    let onNotNow: () -> Void
    let onNext: (CloudWelcomeNextStep) -> Void
    /// Where each slide's clip lives (the lab points this at a folder).
    var mediaURL: (CloudWelcomeSlide) -> URL? = CloudWelcomeMediaCarousel.bundledMediaURL
    // Lab toggles while the slider is designed.
    var showsMedia = true
    var showsReasons = true
    var sliderAutoplays = true
    var sliderShowsFeatureList = true
    var sliderListUsesDots = false

    static let windowWidth: CGFloat = 580
    /// The list layouts put the features beside the clip, so they need more room.
    static let listWindowWidth: CGFloat = 680

    var body: some View {
        let hasMedia = showsMedia && CloudWelcomeSlide.all.contains { mediaURL($0) != nil }
        return VStack(spacing: 0) {
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
        .frame(width: sliderShowsFeatureList && hasMedia ? Self.listWindowWidth : Self.windowWidth)
        .background(windowBackground)
        .accessibilityIdentifier("CloudWelcomeWindow")
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
            return [String(localized: "cloud.welcome.note.included", defaultValue: "Included in your plan.")]
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
