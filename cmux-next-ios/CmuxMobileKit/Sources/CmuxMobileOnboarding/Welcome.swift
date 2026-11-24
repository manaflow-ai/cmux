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

/// Signed-out welcome (onboarding design spec, section 2), composed like
/// Claude's: the cmux lockup at the top, an illustration and one serif line in
/// the middle, the sign-in rows and legal line at the bottom. On a cold launch
/// it plays a ~4 s intro on one clock: the launch mark glides into the lockup
/// while the text and buttons come up from 35% (usable at once), then the
/// illustration draws itself. Afterwards it rests; one idle event plays 4 s
/// later, then nothing moves. At accessibility text sizes the art goes, the
/// labels wrap, and the page scrolls when it has to.
public struct WelcomeView: View {
    let auth: CmuxMobileAuthModel
    let initialEmail: String?
    @State private var showsEmail = false
    /// The intro has started (the lockup slot is measured).
    @State private var started: Bool
    /// Why the timeline runs: each animation that moves adds its own reason
    /// and takes back only its own, and the timeline pauses when none is left.
    /// (One shared flag let the intro's end stop a reveal the picker had just
    /// started, freezing it mid-reveal, sometimes on a blank frame.)
    @State private var awake: Set<Wake> = [.intro]
    @State private var idleStart: Date?
    @State private var lockupMark: CGRect = .zero
    /// The sign-in icons grow with their labels (18 pt at the default size,
    /// capped at 28 pt so a two-line label still fits beside it).
    @ScaledMetric(relativeTo: .headline) private var scaledIcon: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    /// The lockup's chevron grows with the wordmark (capped).
    @ScaledMetric(relativeTo: .title2) private var scaledLockupMark: CGFloat = 22
    /// Prototype: which top section shows (`WelcomeHero.swift`), whether a
    /// launch argument pinned it (no picker), and when a picker switch or
    /// replay re-mounted it (its entrance plays from there).
    @State private var hero: WelcomeHeroVariant
    @State private var heroPinned: Bool
    @State private var heroShownAt: Date?

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
        _lockupMark = State(initialValue: clock.lockupMark)
        let choice = WelcomeHeroVariant.launchChoice
        _hero = State(initialValue: choice.variant)
        _heroPinned = State(initialValue: choice.pinned)
    }

    private var lockupMarkSize: CGFloat { min(scaledLockupMark, 48) }
    private static let launchMarkSize: CGFloat = 72

    public var body: some View {
        TimelineView(.animation(paused: awake.isEmpty)) { context in
            let t = WelcomeIntroClock.shared.time(at: context.date)
            content(t: t, idle: idleTime(at: context.date), date: context.date)
        }
        .sheet(isPresented: $showsEmail) {
            EmailSignInSheet(auth: auth, initialEmail: initialEmail)
        }
        .task(id: started) { await runClock() }
        .task(id: heroShownAt) { await runHeroEntrance() }
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

    private func content(t rawT: Double, idle: Double?, date: Date) -> some View {
        typealias E = IntroEase
        // Reduce Motion: everything crossfades into its settled state.
        let fade = reduceMotion ? E.seg(rawT, 0, 0.35) : 1
        let t = reduceMotion ? .infinity : rawT
        // The headline, buttons and legal line are at 35% on the first frame
        // and reach 100% together in 0.22 s: no stagger, no rise.
        // Until the intro starts, the welcome is the launch screen: the 72 pt
        // mark alone (iOS is still crossfading its launch screen into it).
        var introStarted = (WelcomeIntroClock.shared.t ?? -1) >= 0
        #if DEBUG
        // A frozen intro (verification) shows the controls at the frozen time.
        if let frozen = WelcomeIntroClock.debugFreeze { introStarted = frozen >= 0 }
        #endif
        let controls = !introStarted ? 0 : reduceMotion ? fade : 0.35 + 0.65 * E.out(E.seg(t, 0, 0.22))
        let large = dynamicTypeSize.isAccessibilitySize
        // A picker switch or replay plays the new hero's entrance from that moment.
        // Never before it: a paused timeline still reports its last frame's
        // date, so the first frame after a switch can read up to seconds early.
        let heroT = reduceMotion ? .infinity : heroShownAt.map { max(0, date.timeIntervalSince($0)) } ?? t
        return ZStack {
            theme.colors.bg.color.ignoresSafeArea()
            ViewThatFits(in: .vertical) {
                // Fits: the hero centers in the space between the lockup and
                // the buttons.
                column(t: t, heroT: heroT, idle: idle, fade: fade, controls: controls, showsArt: !large, fills: true)
                // Larger text: the same column, scrolling.
                ScrollView {
                    column(t: t, heroT: heroT, idle: idle, fade: fade, controls: controls, showsArt: false, fills: false)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // The prototype picker sits above the page, never over it.
            .safeAreaInset(edge: .top, spacing: 0) { heroPicker }
            launchMark(t: rawT)
        }
        // A direction with no chevron slot starts the intro on its own.
        .onChange(of: scenePhase, initial: true) { _, _ in startIntroIfReady() }
    }

    /// DEBUG, unless a launch argument pinned a variant: the prototype picker.
    @ViewBuilder
    private var heroPicker: some View {
        #if DEBUG
        if !heroPinned {
            WelcomeHeroPicker(selection: $hero) { heroShownAt = .now }
                .padding(.vertical, 6)
                .onChange(of: hero) { heroShownAt = .now }
        }
        #endif
    }

    /// Keeps the timeline running while a re-mounted hero plays its entrance.
    /// A newer switch cancels this one and adds `.hero` again itself.
    private func runHeroEntrance() async {
        guard heroShownAt != nil else { return }
        awake.insert(.hero)
        try? await ContinuousClock().sleep(for: .seconds(hero.entranceDuration))
        guard !Task.isCancelled else { return }
        awake.remove(.hero)
    }

    private func column(t: Double, heroT: Double, idle: Double?, fade: Double, controls: Double, showsArt: Bool, fills: Bool) -> some View {
        VStack(spacing: 0) {
            // Today's design keeps its lockup at the top; the directions put
            // the mark in the middle and nothing above it.
            if hero == .now {
                lockup(t: t).opacity(fade).padding(.top, 8)
            }
            if fills { Spacer(minLength: 24) }
            heroSection(t: t, heroT: heroT, idle: idle, fade: fade, controls: controls, showsArt: showsArt)
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

    /// The top section above the sign-in rows, per prototype variant.
    @ViewBuilder
    private func heroSection(t: Double, heroT: Double, idle: Double?, fade: Double, controls: Double, showsArt: Bool) -> some View {
        switch hero {
        case .now:
            VStack(spacing: 32) {
                if showsArt {
                    WelcomeArt(t: heroT, idle: reduceMotion ? nil : idle)
                        .opacity(fade)
                }
                Text("Your Macs, in your pocket.")
                    .font(theme.type.welcomeTitle)
                    .foregroundStyle(theme.colors.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(showsArt ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .opacity(controls)
                    .accessibilityAddTraits(.isHeader)
            }
        case .lockup:
            WelcomeHeroLockup(t: heroT) { markSlot(size: WelcomeHeroLockup<EmptyView>.markSize) }
                .opacity(fade)
        case .site:
            WelcomeHeroSite(t: heroT, blinks: cursorBlinks).opacity(fade)
        case .bloom:
            WelcomeHeroBloom(t: heroT).opacity(fade)
        case .morph:
            WelcomeHeroMorph(t: heroT).opacity(fade)
        case .glide, .glide450, .glide600, .glide900:
            WelcomeHeroMorph(t: heroT, variant: hero).opacity(fade)
        case .decode:
            WelcomeHeroDecode(t: heroT).opacity(fade)
        case .shimmer:
            WelcomeHeroShimmer(t: heroT).opacity(fade)
        case .raster:
            WelcomeHeroRaster(t: heroT).opacity(fade)
        case .draft:
            WelcomeHeroDraft(t: heroT).opacity(fade)
        case .keys:
            WelcomeHeroKeys(t: heroT).opacity(fade)
        case .circuit:
            WelcomeHeroCircuit(t: heroT).opacity(fade)
        case .tube:
            WelcomeHeroTube(t: heroT).opacity(fade)
        }
    }

    /// Site's caret blinks, except under Reduce Motion and in a frozen
    /// (verification) capture.
    private var cursorBlinks: Bool {
        #if DEBUG
        if WelcomeIntroClock.debugFreeze != nil { return false }
        #endif
        return !reduceMotion
    }

    // MARK: Lockup

    /// The chevron slot (drawn by `launchMark`) and the "cmux" wordmark.
    private func lockup(t: Double) -> some View {
        typealias E = IntroEase
        let word = E.outQuint(E.seg(t, 0.15, 0.5))
        return HStack(spacing: 7) {
            markSlot(size: lockupMarkSize)
            Text(verbatim: "cmux")
                .font(theme.type.welcomeWordmark)
                .foregroundStyle(theme.colors.label)
                .opacity(word)
                .offset(x: -8 * (1 - word))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "cmux"))
    }

    /// Where the launch mark lands: measured, so the mark glides here.
    private func markSlot(size: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                lockupMark = rect
                WelcomeIntroClock.shared.lockupMark = rect
                startIntroIfReady()
            }
            .onChange(of: scenePhase, initial: true) { _, _ in startIntroIfReady() }
    }

    /// The launch screen's mark (72 pt, centered, the app icon's gradient) on
    /// the first frame, gliding into the lockup slot. It stays the lockup's
    /// chevron afterwards, so nothing is swapped.
    private func launchMark(t: Double) -> some View {
        typealias E = IntroEase
        return GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let target = CGPoint(x: lockupMark.midX, y: lockupMark.midY)
            let glide = reduceMotion ? 1 : E.outQuint(E.seg(t, 0, 0.45))
            let size = E.lerp(Self.launchMarkSize, lockupMark.width > 0 ? lockupMark.width : lockupMarkSize, glide)
            // Reduce Motion: the launch mark crossfades into the lockup's.
            let fade = reduceMotion ? E.seg(t, 0, 0.35) : 1
            // A direction without a chevron slot: the launch mark dissolves
            // where it is (shrinking a little) while the wordmark comes in.
            let dissolve = E.out(E.seg(t, 0, 0.3))
            ZStack {
                if !hero.carriesMark {
                    CmuxLogoMark(chevronHeight: Self.launchMarkSize)
                        .scaleEffect(1 - 0.12 * dissolve)
                        .position(center)
                        .opacity(1 - dissolve)
                } else if reduceMotion {
                    CmuxLogoMark(chevronHeight: Self.launchMarkSize)
                        .position(center)
                        .opacity(1 - fade)
                }
                if hero.carriesMark {
                    CmuxLogoMark(chevronHeight: size)
                        .position(lockupMark == .zero ? center : E.lerp(center, target, glide))
                        .opacity(fade)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Starts the intro clock once the lockup slot is measured and the scene
    /// is active, at `-launchCrossfade`: on a cold launch iOS crossfades its
    /// launch screen into the app's first frames (about 0.25 s, and it is
    /// still running when the scene turns active, measured at 60 fps). While
    /// the clock is below 0 the welcome draws exactly the launch screen (the
    /// 72 pt mark alone), so that crossfade shows one chevron; the intro
    /// proper then starts with the controls at 35%. The hold is part of the
    /// intro's own frame clock (it advances with rendered frames), not a sleep.
    private func startIntroIfReady() {
        let clock = WelcomeIntroClock.shared
        if clock.t == nil, clock.lockupMark.width > 0 || !hero.carriesMark, scenePhase == .active {
            clock.t = -(WelcomeIntroClock.launchCrossfade + WelcomeIntroClock.debugHold)
            // When the launch mark starts moving (launch timing checks).
            welcomeLog.info("intro started")
        }
        if !started, clock.t != nil { started = true }
    }

    /// Seconds into the idle event, or nil outside it.
    private func idleTime(at date: Date) -> Double? {
        #if DEBUG
        if let frozen = WelcomeIntroClock.debugPulseFreeze { return frozen }
        #endif
        guard let idleStart else { return nil }
        let u = date.timeIntervalSince(idleStart)
        return u < WelcomeArt.idleDuration ? u : nil
    }

    /// Stops the timeline when the intro settles, then wakes it once for the
    /// idle event 4 s later; after that the welcome is still. These are
    /// intentional, bounded pauses on the clock the intro already runs on,
    /// not synchronization.
    private func runClock() async {
        guard started else { return }
        let clock = ContinuousClock()
        let end = reduceMotion ? 0.4 : WelcomeArt.introDuration + 0.05
        while let t = WelcomeIntroClock.shared.t, t < end {
            try? await clock.sleep(for: .seconds(end - t))
            guard !Task.isCancelled else { return }
        }
        awake.remove(.intro)
        WelcomeIntroClock.shared.logFramePacing()
        openRequestedEmail()
        guard !reduceMotion, !WelcomeIntroClock.shared.idlePlayed else { return }
        try? await clock.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        WelcomeIntroClock.shared.idlePlayed = true
        idleStart = .now
        awake.insert(.idle)
        try? await clock.sleep(for: .seconds(WelcomeArt.idleDuration + 0.05))
        awake.remove(.idle)
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

/// A reason the welcome's timeline runs (`WelcomeView.awake`).
private enum Wake: Hashable {
    /// The launch intro, until it settles.
    case intro
    /// The idle event, once, a few seconds after the intro.
    case idle
    /// A direction the prototype picker switched to or replayed, until its
    /// entrance ends.
    case hero
}

/// When this process's welcome intro started (it plays once per cold launch),
/// and where the lockup's chevron sits.
/// It advances with rendered frames, each step capped at 1/30 s, so a stalled
/// main thread (first launch, font loading) pauses the intro instead of
/// skipping part of it.
@MainActor
private final class WelcomeIntroClock {
    static let shared = WelcomeIntroClock()
    /// Seconds of intro shown; nil until it starts, `.infinity` when settled.
    var t: Double?
    var lockupMark: CGRect = .zero
    /// How long the welcome holds the launch screen's frame before the intro
    /// starts: iOS's launch-screen crossfade (about 0.25 s) plus a margin.
    static let launchCrossfade: Double = 0.3
    /// The one idle event has played (it never repeats in this process).
    var idlePlayed = false
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
    /// `-cmux-mobile-pulse-freeze <s>` (verification): hold the idle pulse at that time.
    static let debugPulseFreeze: Double? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cmux-mobile-pulse-freeze"), i + 1 < arguments.count else { return nil }
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
            if step > 0, t > 0, t < WelcomeArt.introDuration { frameSteps.append(step) }
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
