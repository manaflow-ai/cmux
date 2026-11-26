#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import os
import SwiftUI

private let welcomeLog = Logger(subsystem: "dev.cmux.mobile", category: "welcome")

private let theme = CmuxMobileTheme.standard

/// The launch screen's mark, re-drawn as the first SwiftUI frame so the handoff
/// is seamless (SPEC 5.1): the same image, same 72 pt chevron, same center, on `bg`.
public struct LaunchMarkView: View {
    public init() {}

    public var body: some View {
        // Full screen, so the root's `ignoresSafeArea` centers the mark on the
        // screen as iOS centers the launch image, not in the safe area.
        CmuxLogoMark(chevronHeight: 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { LaunchMarks.shared.markNextFrame("first_frame") }
    }
}

/// Signed-out welcome: the cmux wordmark and one gray line in the middle
/// (`WelcomeGlide`), the sign-in rows (system glass) and the legal line at the
/// bottom. On a cold launch it plays a 2.4 s intro on one clock: the launch
/// mark dissolves while the buttons come up from 35% (usable at once), and
/// the wordmark's cursor blinks, types "cmux" and flies home as the chevron.
/// Afterwards nothing moves. At accessibility text sizes the labels wrap and
/// the page scrolls when it has to.
public struct WelcomeView: View {
    let auth: CmuxMobileAuthModel
    let initialEmail: String?
    @State private var showsEmail = false
    /// The intro has started (the scene is active).
    @State private var started: Bool
    /// The timeline runs while the intro plays. Only `runClock` writes it: a
    /// second writer (the prototype picker's entrances) once let the intro's
    /// end stop a reveal mid-way, sometimes on a blank frame.
    @State private var animating = true
    /// The sign-in icons grow with their labels (18 pt at the default size,
    /// capped at 28 pt so a two-line label still fits beside it).
    @ScaledMetric(relativeTo: .headline) private var scaledIcon: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// `playsLaunchIntro`: the welcome replaces the launch screen (cold launch);
    /// false after sign-out, where the root crossfades it in, settled.
    /// `initialEmail` (DEBUG verification) opens the email sheet on the code step.
    public init(auth: CmuxMobileAuthModel, playsLaunchIntro: Bool = true, initialEmail: String? = nil) {
        self.auth = auth
        self.initialEmail = initialEmail
        // The intro's clock is per process: a Welcome rebuilt mid-intro picks
        // it up where it is instead of replaying or skipping to the end.
        let clock = WelcomeIntroClock.shared
        if !playsLaunchIntro, clock.t == nil { clock.t = .infinity }
        _started = State(initialValue: clock.t != nil)
    }

    private static let launchMarkSize: CGFloat = 72

    public var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            content(t: WelcomeIntroClock.shared.time(at: context.date))
        }
        .sheet(isPresented: $showsEmail) {
            EmailSignInSheet(auth: auth, initialEmail: initialEmail)
        }
        .task(id: started) { await runClock() }
        // Leaving Welcome (signed in) ends the intro; a later sign-out shows it settled.
        .onDisappear { WelcomeIntroClock.shared.t = .infinity }
        .cmuxMobileSensoryFeedback(.error, trigger: auth.errorMessage)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            if DemoDirector.shared.command == .onboardingOpenEmail { showsEmail = true }
        }
        .task {
            if OnboardingDemoScript.isRequested { OnboardingDemoScript.start() }
        }
        #endif
    }

    private func content(t rawT: Double) -> some View {
        typealias E = IntroEase
        // Reduce Motion: everything crossfades into its settled state.
        let fade = reduceMotion ? E.seg(rawT, 0, 0.35) : 1
        let t = reduceMotion ? .infinity : rawT
        // The buttons and legal line are at 35% on the first frame
        // and reach 100% together in 0.22 s: no stagger, no rise.
        // Until the intro starts, the welcome is the launch screen: the 72 pt
        // mark alone (iOS is still crossfading its launch screen into it).
        var introStarted = (WelcomeIntroClock.shared.t ?? -1) >= 0
        #if DEBUG
        // A frozen intro (verification) shows the controls at the frozen time.
        if let frozen = WelcomeIntroClock.debugFreeze { introStarted = frozen >= 0 }
        #endif
        let controls = !introStarted ? 0 : reduceMotion ? fade : 0.35 + 0.65 * E.out(E.seg(t, 0, 0.22))
        return ZStack {
            theme.colors.bg.color.ignoresSafeArea()
            ViewThatFits(in: .vertical) {
                // Fits: the wordmark centers in the space above the buttons.
                column(t: t, fade: fade, controls: controls, fills: true)
                // Larger text: the same column, scrolling.
                ScrollView {
                    column(t: t, fade: fade, controls: controls, fills: false)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            launchMark(t: rawT)
        }
        .onChange(of: scenePhase, initial: true) { _, _ in startIntroIfReady() }
    }

    private func column(t: Double, fade: Double, controls: Double, fills: Bool) -> some View {
        VStack(spacing: 0) {
            if fills { Spacer(minLength: 24) }
            WelcomeGlide(t: t)
                .opacity(fade)
                // Optical center: a little above the middle of the free space.
                .offset(y: fills ? -16 : 0)
                .padding(.vertical, fills ? 0 : 32)
            if fills { Spacer(minLength: 72) }
            buttons
                .opacity(controls)
                .overlay(alignment: .top) { errorLine }
                // A phone's width: an unfolded foldable keeps them centered, not 750 pt wide.
                .frame(maxWidth: 440)
                .padding(.horizontal, theme.metrics.sideMargin)
            legal
                .opacity(controls)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
    }

    /// The launch screen's mark (72 pt, centered, the app icon's gradient) on
    /// the first frame. It dissolves where it is (shrinking a little) while
    /// the wordmark's cursor starts to blink; Reduce Motion crossfades it out.
    private func launchMark(t: Double) -> some View {
        typealias E = IntroEase
        return GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let dissolve = reduceMotion ? E.seg(t, 0, 0.35) : E.out(E.seg(t, 0, 0.3))
            CmuxLogoMark(chevronHeight: Self.launchMarkSize)
                .scaleEffect(reduceMotion ? 1 : 1 - 0.12 * dissolve)
                .position(center)
                .opacity(1 - dissolve)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Starts the intro clock once the scene is active, at `-launchCrossfade`:
    /// on a cold launch iOS crossfades its launch screen into the app's first
    /// frames (about 0.25 s, and it is
    /// still running when the scene turns active, measured at 60 fps). While
    /// the clock is below 0 the welcome draws exactly the launch screen (the
    /// 72 pt mark alone), so that crossfade shows one chevron; the intro
    /// proper then starts with the controls at 35%. The hold is part of the
    /// intro's own frame clock (it advances with rendered frames), not a sleep.
    private func startIntroIfReady() {
        let clock = WelcomeIntroClock.shared
        if clock.t == nil, scenePhase == .active {
            clock.t = -(WelcomeIntroClock.launchCrossfade + WelcomeIntroClock.debugHold)
            // When the launch mark starts moving (launch timing checks).
            welcomeLog.info("intro started")
        }
        if !started, clock.t != nil { started = true }
    }

    /// Stops the timeline when the intro settles; after that the welcome is
    /// still. The wait is on the clock the intro already runs on, not
    /// synchronization.
    private func runClock() async {
        guard started else { return }
        let clock = ContinuousClock()
        let end = reduceMotion ? 0.4 : WelcomeGlide.entranceDuration + 0.05
        while let t = WelcomeIntroClock.shared.t, t < end {
            try? await clock.sleep(for: .seconds(end - t))
            guard !Task.isCancelled else { return }
        }
        animating = false
        // Settled for good: the paused timeline's last time could sit in a
        // blank moment of the reveal (Reduce Motion stops at 0.4 s, in the
        // cursor's off gap), and turning Reduce Motion off would then redraw
        // it there with nothing to move it on.
        WelcomeIntroClock.shared.t = .infinity
        WelcomeIntroClock.shared.logFramePacing()
        openRequestedEmail()
    }

    /// DEBUG verification opens the sheet the way a tap would.
    private func openRequestedEmail() {
        if initialEmail != nil, !showsEmail { showsEmail = true }
    }

    // MARK: Buttons

    /// Production: Google, GitHub, email. Builds that can sign in with Apple
    /// (TestFlight) put Apple first. The first row is the solid one.
    private var buttons: some View {
        let apple = BuildCapabilities.current.appleSignIn
        let icon = min(scaledIcon, 28)
        // One container so the rows' glass samples together; spacing 0 keeps them apart.
        return GlassEffectContainer(spacing: 0) {
            VStack(spacing: theme.metrics.ctaWelcomeGap) {
                if apple {
                    ProviderButton(title: "Continue with Apple", isPrimary: true, isBusy: auth.busyProvider == .apple, signInBusy: auth.isBusy) {
                        Image(systemName: "apple.logo").font(.system(size: icon + 1, weight: .medium))
                    } action: { signIn(.apple) }
                }
                ProviderButton(title: "Continue with Google", isPrimary: !apple, isBusy: auth.busyProvider == .google, signInBusy: auth.isBusy) {
                    Image("GoogleLogo", bundle: .module).resizable().frame(width: icon, height: icon)
                } action: { signIn(.google) }
                ProviderButton(title: "Continue with GitHub", isPrimary: false, isBusy: auth.busyProvider == .github, signInBusy: auth.isBusy) {
                    Image("GitHubLogo", bundle: .module).renderingMode(.template).resizable().frame(width: icon, height: icon)
                } action: { signIn(.github) }
                ProviderButton(title: "Continue with email", isPrimary: false, isBusy: false, signInBusy: auth.isBusy) {
                    Image(systemName: "envelope").font(.system(size: icon - 1, weight: .medium))
                } action: {
                    auth.errorMessage = nil
                    showsEmail = true
                }
            }
        }
    }

    private func signIn(_ provider: CmuxMobileAuthModel.Provider) {
        Task { await auth.signIn(with: provider) }
    }

    /// A failed sign-in: one line in the empty band above the first row,
    /// overlaid so nothing moves. Two lines grow upward.
    private var errorLine: some View {
        ZStack(alignment: .bottom) {
            if let error = auth.errorMessage {
                Text(error)
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.dangerText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .accessibilityIdentifier("welcome.error")
            }
        }
        .alignmentGuide(.top) { $0[.bottom] + 12 }
        .animation(theme.motion.snap.animation.unlessReduceMotion, value: auth.errorMessage)
    }

    private var legal: some View {
        Text(Self.legalText)
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.legal)
            .tint(theme.colors.label.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, theme.metrics.sideMargin)
            .environment(\.openURL, OpenURLAction { _ in .systemAction })
    }

    /// The legal line, its links underlined.
    private static let legalText: AttributedString = {
        var text = (try? AttributedString(markdown: String(localized: "By continuing, you agree to the [Terms](https://cmux.com/terms-of-service) and [Privacy Policy](https://cmux.com/privacy-policy)."))) ?? AttributedString()
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
        }
        return text
    }()
}

/// When this process's welcome intro started (it plays once per cold launch).
/// It advances with rendered frames, each step capped at 1/30 s, so a stalled
/// main thread (first launch, font loading) pauses the intro instead of
/// skipping part of it.
@MainActor
private final class WelcomeIntroClock {
    static let shared = WelcomeIntroClock()
    /// Seconds of intro shown; nil until it starts, `.infinity` when settled.
    var t: Double?
    /// How long the welcome holds the launch screen's frame before the intro
    /// starts: iOS's launch-screen crossfade (about 0.25 s) plus a margin.
    static let launchCrossfade: Double = 0.3
    private var lastFrame: Date?

    #if DEBUG
    private var frameSteps: [Double] = []
    /// `-cmux-mobile-intro-hold <s>` (verification): rest on the launch mark first, so
    /// a screen recorder is past the launch burst when the intro starts.
    static var debugHold: Double {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cmux-mobile-intro-hold"), i + 1 < arguments.count else { return 0 }
        return Double(arguments[i + 1]) ?? 0
    }

    /// Frame pacing of the intro, measured in the app (the simulator's recorder
    /// retimes frames under load, so its timestamps cannot show jank).
    func logFramePacing() {
        guard !frameSteps.isEmpty else { return }
        let sorted = frameSteps.sorted()
        let p50 = sorted[sorted.count / 2], worst = sorted[sorted.count - 1]
        let long = frameSteps.filter { $0 > p50 * 1.5 }.count
        welcomeLog.info("intro pacing: frames=\(self.frameSteps.count, privacy: .public) p50=\(p50 * 1000, privacy: .public)ms max=\(worst * 1000, privacy: .public)ms long=\(long, privacy: .public)")
        frameSteps = []
    }
    /// `-cmux-mobile-intro-freeze <s>` (verification): hold the intro at that time, for
    /// exact timeline screenshots.
    static let debugFreeze: Double? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cmux-mobile-intro-freeze"), i + 1 < arguments.count else { return nil }
        return Double(arguments[i + 1])
    }()
    #else
    static let debugHold: Double = 0
    func logFramePacing() {}
    #endif

    func time(at date: Date) -> Double {
        guard var t else { return 0 }
        #if DEBUG
        if let frozen = Self.debugFreeze { return frozen }
        #endif
        if let lastFrame {
            let step = date.timeIntervalSince(lastFrame)
            t += min(max(step, 0), 1.0 / 30)
            #if DEBUG
            if step > 0, t > 0, t < WelcomeGlide.entranceDuration { frameSteps.append(step) }
            #endif
        }
        lastFrame = date
        self.t = t
        return t
    }
}

/// The cmux chevron: the chevron layer of the app icon (`AppIcon.icon`), the
/// image the launch screen shows (`LaunchMark`, written by
/// `scripts/generate-launch-mark.swift`), glow included. The image is
/// `imageHeight` points tall with its solid chevron `imageChevronHeight` tall
/// at its center; `chevronHeight` scales it so the solid chevron is that tall.
struct CmuxLogoMark: View {
    var chevronHeight: CGFloat

    private static let imageHeight: CGFloat = 86
    private static let imageChevronHeight: CGFloat = 72

    var body: some View {
        // The app's asset catalog (main bundle): the launch screen reads the same entry.
        Image("LaunchMark", bundle: .main)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: Self.imageHeight * chevronHeight / Self.imageChevronHeight)
            .accessibilityHidden(true)
    }
}

/// A welcome sign-in row: a system glass button, full width, growing with
/// Dynamic Type, its label wrapping centered with the icon on the first
/// line. The first row is prominent glass tinted solid (black or white, as
/// Sign in with Apple), the others clear glass. The system glass styles own
/// the touch: a held row stays lit and stretches toward a dragging finger,
/// and dragging off cancels. Busy shows a spinner in place of the icon;
/// while any sign-in runs, the other rows are disabled.
private struct ProviderButton<Icon: View>: View {
    let title: LocalizedStringKey
    let isPrimary: Bool
    let isBusy: Bool
    /// A sign-in is running (this row's or another's).
    let signInBusy: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Half the `cta` cap height: centers the icon on the first line.
    @ScaledMetric(relativeTo: .headline) private var iconLift: CGFloat = 6
    /// The icon's slot: 22 pt, growing with the label like the icon (capped).
    @ScaledMetric(relativeTo: .headline) private var iconSlot: CGFloat = 22

    var body: some View {
        let lift = iconLift
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack {
                    icon().opacity(isBusy ? 0 : 1)
                    if isBusy { CmuxSpinner(tint: isPrimary ? theme.colors.neutralOnAccent.color : theme.colors.label.color) }
                }
                .frame(width: min(iconSlot, 30), height: min(iconSlot, 30))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(theme.type.cta)
            .foregroundStyle(isPrimary ? theme.colors.neutralOnAccent : theme.colors.label)
            // Accessibility sizes: a little less side room, for the larger icon.
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 0 : 4)
            .frame(maxWidth: .infinity)
        }
        .modifier(ProviderGlass(isPrimary: isPrimary))
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // One plain button element, framed by this row's layout. The
        // prominent glass style's own element reported its frame unconverted
        // in the iPhone app's scaled window on iPad (VoiceOver's focus ring and
        // XCUITest read (20, -29.5, 350, 217.5) for a row drawn at about
        // (232, 528, 568, 354), App Review gate run 45632944865).
        // The represented button carries the busy state itself: hit testing
        // does not reach VoiceOver or XCUITest, so a busy row read as an
        // enabled button (App Review gate run 45090966438, finding F1).
        .accessibilityRepresentation { Button(title, action: action).disabled(signInBusy || isBusy) }
        // The busy row keeps its look (spinner, full colour) but takes no
        // second tap; the others are disabled until the sign-in ends.
        .disabled(signInBusy && !isBusy)
        .allowsHitTesting(!isBusy)
    }
}

/// The rows' system glass. Sign-in buttons stay black or white whatever
/// accent the user picked. The clear rows take the faint `fill` tint where
/// the system offers a tinted glass button (iOS 26.1): over the welcome's
/// flat page there is nothing behind the glass to bend, and untinted it all
/// but vanishes on white.
private struct ProviderGlass: ViewModifier {
    let isPrimary: Bool

    func body(content: Content) -> some View {
        if isPrimary {
            content
                .buttonStyle(.glassProminent)
                .tint(theme.colors.neutralAccent.color)
        } else if #available(iOS 26.1, *) {
            content.buttonStyle(GlassButtonStyle(.regular.tint(theme.colors.fill.color)))
        } else {
            content.buttonStyle(.glass)
        }
    }
}
#endif
