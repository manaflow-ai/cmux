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

    /// The screen room the window may take (its visible frame); nil means
    /// unconstrained, as in the lab.
    var availableSize: CGSize?
    /// Set when the whole welcome would be taller than the screen: the window
    /// takes this height, the footer stays put, and the rest scrolls above it.
    var scrollHeight: CGFloat?
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnificationPercent

    var body: some View {
        let hasMedia = showsMedia && CloudWelcomeSlide.all.contains { mediaURL($0) != nil }
        let layout = CloudWelcomeLayout.resolve(
            prefersFeatureList: sliderShowsFeatureList,
            textScale: CGFloat(magnificationPercent) / 100,
            available: availableSize
        )
        return VStack(spacing: 0) {
            if scrollHeight != nil {
                ScrollView(.vertical) {
                    introduction(hasMedia: hasMedia, layout: layout)
                }
                .frame(maxHeight: .infinity)
            } else {
                introduction(hasMedia: hasMedia, layout: layout)
            }
            panel(hasMedia: hasMedia)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(width: hasMedia ? layout.windowWidth : CloudWelcomeLayout.stackedWindowWidth, height: scrollHeight)
        .background(windowBackground)
        .accessibilityIdentifier("CloudWelcomeWindow")
    }

    /// The title and the clips (or the hero without them).
    @ViewBuilder
    private func introduction(hasMedia: Bool, layout: CloudWelcomeLayout) -> some View {
        VStack(spacing: 0) {
            CloudWelcomeHeader()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 26)
            if hasMedia {
                CloudWelcomeMediaCarousel(
                    slides: CloudWelcomeSlide.all,
                    mediaURL: mediaURL,
                    mediaSize: layout.mediaSize,
                    autoplays: sliderAutoplays,
                    showsFeatureList: layout.showsFeatureList,
                    listUsesDots: sliderListUsesDots
                )
                .padding(.bottom, 28)
            } else {
                CloudWelcomeHero()
            }
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
                        defaultValue: "Invite teammates to the same machine and work together."
                    )
                )
            }
            .padding(.bottom, 20)
            }
            Divider()
            footer
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The note beside the buttons; with large text or long translations the
    /// buttons drop below the note rather than clip.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                note
                Spacer(minLength: 16)
                buttons
            }
            VStack(alignment: .trailing, spacing: 12) {
                note
                    .frame(maxWidth: .infinity, alignment: .leading)
                buttons
            }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(noteLines, id: \.self) { line in
                Text(line)
            }
        }
        .cmuxFont(size: 12)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onNotNow) {
                Text(String(localized: "common.notNow", defaultValue: "Not Now"))
                    .cmuxFont(size: 14)
                    .padding(.horizontal, 8)
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
                    .cmuxFont(size: 14, weight: .semibold)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .environment(\.controlActiveState, .key)
            // No Return shortcut: the window appears on its own at launch, and a
            // Return meant for the terminal must not enable Cloud or open pricing.
            .accessibilityIdentifier("CloudWelcomePrimaryButton")
        }
        .fixedSize()
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

/// The welcome's size for the room it has. The feature list sits beside the
/// clip only while its titles keep a readable column at the current cmux text
/// size; short of that the clip shrinks to a floor, then the list gives way to
/// the stacked layout (clip, dots and caption). The clip also shrinks toward
/// the screen's height; past its floor the window controller scrolls the top.
struct CloudWelcomeLayout: Equatable {
    var showsFeatureList: Bool
    var windowWidth: CGFloat
    var mediaSize: CGSize

    nonisolated static let stackedWindowWidth: CGFloat = 680
    nonisolated static let listWindowWidth: CGFloat = 840
    /// The largest clips: no wider than half the recorded clips' pixels (most
    /// are 1010x640) so they stay sharp on a Retina display.
    nonisolated static let stackedMaxMediaWidth: CGFloat = 500
    nonisolated static let listMaxMediaWidth: CGFloat = 480
    /// Below this the clip is too small to read beside the list.
    nonisolated static let listMinMediaWidth: CGFloat = 380
    nonisolated static let stackedMinMediaWidth: CGFloat = 280
    /// About 16:10, like the clips (the fill crops the rest a little).
    nonisolated static let mediaAspect: CGFloat = 1.6
    nonisolated static let horizontalPadding: CGFloat = 32
    nonisolated static let listSpacing: CGFloat = 24
    /// The feature titles' column at 100% text.
    nonisolated static let listColumnWidth: CGFloat = 240
    /// Room kept between the window and the screen edges.
    nonisolated static let screenMargin: CGFloat = 40
    /// The window's height besides the clip at 100% text: title, pager and
    /// caption (stacked) or the list's overflow, and the footer.
    nonisolated static let stackedChromeHeight: CGFloat = 330
    nonisolated static let listChromeHeight: CGFloat = 240

    nonisolated static func resolve(
        prefersFeatureList: Bool,
        textScale: CGFloat,
        available: CGSize?
    ) -> CloudWelcomeLayout {
        let scale = max(textScale, 1)
        let room = available.map {
            CGSize(width: $0.width - screenMargin, height: $0.height - screenMargin)
        } ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        func widthFittingHeight(chrome: CGFloat) -> CGFloat {
            (room.height - chrome * scale) * mediaAspect
        }
        if prefersFeatureList {
            let window = min(listWindowWidth, room.width)
            let besideList = window - horizontalPadding * 2 - listSpacing - listColumnWidth * scale
            let media = min(listMaxMediaWidth, besideList, widthFittingHeight(chrome: listChromeHeight)).rounded(.down)
            if media >= listMinMediaWidth {
                return CloudWelcomeLayout(showsFeatureList: true, windowWidth: window, mediaSize: size(width: media))
            }
        }
        let window = min(stackedWindowWidth, room.width)
        let media = max(
            stackedMinMediaWidth,
            min(stackedMaxMediaWidth, window - horizontalPadding * 2, widthFittingHeight(chrome: stackedChromeHeight))
        ).rounded(.down)
        return CloudWelcomeLayout(showsFeatureList: false, windowWidth: window, mediaSize: size(width: media))
    }

    private nonisolated static func size(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width / mediaAspect).rounded(.down))
    }
}

/// The "cmux cloud" badge's colors. In dark mode it is the accent on a faint
/// accent tint. Light mode's glass reads mid-gray behind an inactive window, where
/// that tint left the accent text too faint, so the text sits on a light, mostly
/// opaque fill and darkens the accent only as far as WCAG AA needs.
enum CloudWelcomeBadgeStyle {
    nonisolated static let lightFillWhite: CGFloat = 1
    nonisolated static let lightFillOpacity: CGFloat = 0.7
    /// The darkest gray the glass shows through the fill (checked, with margin).
    nonisolated static let darkestBackdropWhite: CGFloat = 0.5
    /// WCAG AA is 4.5:1. The text renders lighter in the glass than its color
    /// (measured 4.15:1 from a modeled 5.1:1), so the model aims higher.
    nonisolated static let minimumContrast: CGFloat = 6.5

    /// The fill as it looks over the darkest backdrop.
    nonisolated static var worstFill: NSColor {
        NSColor(white: lightFillWhite * lightFillOpacity + darkestBackdropWhite * (1 - lightFillOpacity), alpha: 1)
    }

    /// The accent, darkened in small steps until it reads on ``worstFill``.
    nonisolated static func lightText(accent: NSColor) -> NSColor {
        let resolved = accent.usingColorSpace(.sRGB) ?? accent
        let fill = worstFill
        for step in 0...20 {
            let fraction = CGFloat(step) * 0.05
            let candidate = resolved.blended(withFraction: fraction, of: .black) ?? resolved
            if contrast(candidate, fill) >= minimumContrast { return candidate }
        }
        return .black
    }

    /// The WCAG 2 contrast ratio between two opaque colors.
    nonisolated static func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private struct CloudWelcomeHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill")
                    .cmuxFont(size: 12, weight: .semibold)
                Text(String(localized: "cloud.welcome.title.eyebrow", defaultValue: "cmux cloud"))
                    .cmuxFont(size: 13, weight: .semibold)
            }
            .foregroundStyle(isLight ? Color(nsColor: CloudWelcomeBadgeStyle.lightText(accent: .controlAccentColor)) : Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isLight
                        ? Color(white: CloudWelcomeBadgeStyle.lightFillWhite, opacity: CloudWelcomeBadgeStyle.lightFillOpacity)
                        : Color.accentColor.opacity(0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isLight ? 0.3 : 0.18), lineWidth: 0.5)
            }
            Text(String(localized: "cloud.welcome.title", defaultValue: "Your work, wherever you go"))
                .cmuxFont(size: 34, weight: .bold)
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var isLight: Bool { colorScheme == .light }
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
