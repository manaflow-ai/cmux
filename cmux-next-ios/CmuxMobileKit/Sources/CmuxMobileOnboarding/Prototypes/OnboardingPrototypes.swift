#if os(iOS) && DEBUG
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI
import UIKit
import UserNotifications

private let theme = CmuxMobileTheme.standard

/// DEBUG: five whole-onboarding prototypes to flip through on a phone (Aziz 2026-11-23:
/// "5 more ways of doing our entire onboarding flow ... natively on the iOS app").
/// Each is a working flow on mock data: sign-in, connecting a Mac, notifications
/// and a first task. Nothing here signs in, pairs or sends anything; the
/// notifications ask is the real system prompt. Opened with
/// `-cmux-mobile-onboarding-prototypes [1-5]`; the bar at the bottom switches
/// flows and replays the current one.
public struct OnboardingPrototypesView: View {
    public enum Variant: Int, CaseIterable, Identifiable, Sendable {
        case live = 1, thread, homeFirst, oneScene, threeScreens

        public var id: Int { rawValue }

        var name: String {
            switch self {
            case .live: "Live"
            case .thread: "Thread"
            case .homeFirst: "Home"
            case .oneScene: "Scene"
            case .threeScreens: "Three"
            }
        }

        /// The idea it tests, shown under the bar.
        var axis: String {
            switch self {
            case .live: "Answer a real agent request first, then set up"
            case .thread: "Chief sets you up in a conversation"
            case .homeFirst: "Straight to Home; setup is a checklist"
            case .oneScene: "One scene that changes as you set up"
            case .threeScreens: "Three screens, big type, one decision each"
            }
        }
    }

    @State private var variant: Variant
    @State private var run = 0
    private let close: () -> Void

    public init(initial: Variant = .live, close: @escaping () -> Void) {
        _variant = State(initialValue: initial)
        self.close = close
    }

    /// The flow a launch asks for (`-cmux-mobile-onboarding-prototypes 3`), nil when not asked.
    public static func launchVariant(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Variant? {
        guard let index = arguments.firstIndex(of: "-cmux-mobile-onboarding-prototypes") else { return nil }
        let next = arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        return next.flatMap(Variant.init(rawValue:)) ?? .live
    }

    public var body: some View {
        Group {
            switch variant {
            case .live: ProtoLive()
            case .thread: ProtoThread()
            case .homeFirst: ProtoHomeFirst()
            case .oneScene: ProtoOneScene()
            case .threeScreens: ProtoThreeScreens()
            }
        }
        // Every step fills the screen, short ones too, so the app under the gallery never shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A new id restarts the flow from its first screen.
        .id("\(variant.rawValue)-\(run)")
        .safeAreaInset(edge: .bottom, spacing: 0) { picker }
        .background(theme.colors.bg.color.ignoresSafeArea())
    }

    /// The harness bar: not part of any design. Dark glass in both modes.
    private var picker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Variant.allCases) { item in
                    Button {
                        theme.haptics.selection()
                        variant = item
                        run += 1
                    } label: {
                        Text("\(item.rawValue) \(item.name)")
                            .font(theme.type.meta.weight(.semibold))
                            .foregroundStyle(item == variant ? Color.white : Color.white.opacity(0.55))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(item == variant ? Color.white.opacity(0.16) : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.cmuxPressFill)
                    .accessibilityAddTraits(item == variant ? .isSelected : [])
                    .accessibilityIdentifier("proto.variant.\(item.rawValue)")
                }
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 2)
                Button { run += 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text("Replay"))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text("Close prototypes"))
            }
            .padding(4)
            .background(Color.black.opacity(0.86), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            Text(variant.axis)
                .font(theme.type.legal)
                .foregroundStyle(theme.colors.label2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces

private enum Proto {
    static let user = "aziz@example.com"
    static let mac = "Aziz's MacBook Pro"
    static let starters = [
        "Fix the failing tests in api-server",
        "Review my open pull requests",
        "Summarize what changed today",
        "Find a TODO and fix it",
    ]
    static let gradient = LinearGradient(colors: [Color(hex: "#06CDFE"), Color(hex: "#2AA0F9"), Color(hex: "#5170F3")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Demo pacing for a prototype's mock steps (a Mac "found", a line "typed"): an
/// intentional, bounded delay, never synchronization.
@MainActor private func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(UIAccessibility.isReduceMotionEnabled ? min(milliseconds, 250) : milliseconds))
}

@MainActor private func animate(_ spring: CmuxMobileSpring = theme.motion.smooth, _ body: () -> Void) {
    withAnimation(spring.animation.unlessReduceMotion, body)
}

/// The real system prompt; a phone that already answered just goes on.
@MainActor private func askForNotifications() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
}

/// The app icon: the gradient chevron on black.
private struct ProtoMark: View {
    var size: CGFloat = 64

    var body: some View {
        CmuxMark()
            .fill(Proto.gradient)
            .frame(width: size * 0.42, height: size * 0.42)
            .frame(width: size, height: size)
            .background(Color.black, in: .rect(cornerRadius: size * 0.235, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: size * 0.18, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

/// A full-width capsule: `primary` is the neutral CTA, otherwise a provider fill.
private struct ProtoButton: View {
    let title: LocalizedStringKey
    var method: SignInMethod?
    var primary = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    if let method { SignInMethodGlyph(method, size: 18) }
                    Text(title)
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading { CmuxSpinner(tint: primary ? theme.colors.neutralOnAccent.color : theme.colors.label.color) }
            }
        }
        .buttonStyle(CmuxMobileCapsuleStyle(size: .large, kind: primary ? .primary : .provider))
        .allowsHitTesting(!isLoading)
    }
}

/// Apple first and solid; the rest as providers; email as text.
private struct ProtoSignIn: View {
    var compact = false
    let signIn: (SignInMethod) -> Void
    @State private var busy: SignInMethod?

    var body: some View {
        VStack(spacing: theme.metrics.ctaWelcomeGap) {
            ProtoButton(title: "Continue with Apple", method: .apple, primary: true, isLoading: busy == .apple) { go(.apple) }
            ProtoButton(title: "Continue with Google", method: .google, isLoading: busy == .google) { go(.google) }
            ProtoButton(title: "Continue with GitHub", method: .github, isLoading: busy == .github) { go(.github) }
            TextCTA("Continue with email") { go(.emailCode(Proto.user)) }
        }
    }

    private func go(_ method: SignInMethod) {
        guard busy == nil else { return }
        busy = method
        theme.haptics.impactLight()
        Task { await pause(700); signIn(method) }
    }
}

/// The real notification captures from a simulator (`OnboardingPushShotUITests`).
private struct ProtoPushes: View {
    var radius: CGFloat = 26

    var body: some View {
        Image("OnboardingPushes", bundle: .module)
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .accessibilityLabel(Text("Three cmux notifications: Codex asks to push, Claude Code finished, and a note from Chief"))
    }
}

private struct ProtoPermissionBanner: View {
    var body: some View {
        Image("OnboardingPushPermission", bundle: .module)
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            .accessibilityLabel(Text("Codex wants to act on MacBook Pro: git push origin feat-onboarding"))
    }
}

private struct ProtoChip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.type.chip)
                .foregroundStyle(selected ? theme.colors.neutralOnAccent : theme.colors.label)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? AnyShapeStyle(theme.colors.neutralAccent) : AnyShapeStyle(theme.colors.fill), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.cmuxPressFill)
    }
}

/// Chief's composer: a field and a send button that wakes when there's text.
private struct ProtoComposer: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Ask Chief to do something"
    var focused: FocusState<Bool>.Binding?
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
                .font(theme.type.body)
                .lineLimit(1...4)
                .padding(.vertical, 7)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(theme.type.cta)
                    .foregroundStyle(theme.colors.neutralOnAccent)
                    .frame(width: 34, height: 34)
                    .background(theme.colors.neutralAccent, in: .circle)
                    .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.25 : 1)
            }
            .buttonStyle(.cmuxPressFill)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("proto.send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.composerRadius, style: .continuous))
    }

    @ViewBuilder private var field: some View {
        if let focused {
            TextField(placeholder, text: $text, axis: .vertical).focused(focused).submitLabel(.send).onSubmit(send)
        } else {
            TextField(placeholder, text: $text, axis: .vertical).submitLabel(.send).onSubmit(send)
        }
    }
}

private struct ProtoTypingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.colors.label3)
                    .frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15).unlessReduceMotion, value: on)
            }
        }
        .padding(.vertical, 8)
        .onAppear { on = true }
        .accessibilityLabel(Text("Chief is typing"))
    }
}

/// A running task: spinner, agent and place.
private struct ProtoTaskCard: View {
    var title = "Claude Code · api-server"
    var detail = "Running · started just now"

    var body: some View {
        HStack(spacing: 12) {
            CmuxSpinner(tint: theme.colors.label.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(theme.type.rowSubtitle.weight(.semibold)).foregroundStyle(theme.colors.label)
                Text(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
    }
}

/// "Looking for your Mac" / the Mac's name, in one pill.
private struct ProtoMacStatus: View {
    let found: Bool

    var body: some View {
        HStack(spacing: 8) {
            if found {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.colors.success)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                Text(Proto.mac)
            } else {
                CmuxSpinner(tint: theme.colors.label2.color)
                Text("Looking for your Mac")
            }
        }
        .font(theme.type.rowSubtitle.weight(.medium))
        .foregroundStyle(theme.colors.label)
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(theme.colors.fill, in: .capsule)
    }
}

/// A laptop that lights up with the cmux mark when its Mac connects.
private struct ProtoMacArt: View {
    let lit: Bool
    var width: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.colors.surfaceRaised)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(lit ? AnyShapeStyle(Proto.gradient) : AnyShapeStyle(theme.colors.fillSelected))
                    .padding(6)
                if lit {
                    CmuxMark().fill(Color.white).frame(width: width * 0.11, height: width * 0.16)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .frame(width: width * 0.78, height: width * 0.5)
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 6, bottomTrailing: 6), style: .continuous)
                .fill(theme.colors.surfaceRaised)
                .frame(width: width, height: width * 0.035)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.colors.separator, lineWidth: 0.5)
                .frame(width: width * 0.78, height: width * 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// A floating confirmation, then gone.
private struct ProtoToast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.colors.success)
                    Text(message).font(theme.type.rowSubtitle.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    await pause(2000)
                    animate { self.message = nil }
                }
            }
        }
    }
}

extension View {
    fileprivate func protoToast(_ message: Binding<String?>) -> some View { modifier(ProtoToast(message: message)) }
}

/// Fades and lifts a view in when it appears.
private struct ProtoRise: ViewModifier {
    var delay: Double = 0
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(theme.motion.smooth.animation.delay(delay).unlessReduceMotion) { shown = true }
            }
    }
}

extension View {
    fileprivate func rise(_ delay: Double = 0) -> some View { modifier(ProtoRise(delay: delay)) }
}

// MARK: - 1 · Live

/// An agent asks before anything else; answering it is the pitch. Then sign in,
/// the Mac, notifications ("like you just did") and a first task.
private struct ProtoLive: View {
    private enum Step { case demo, mac, notifications, task, chief }

    @State private var step = Step.demo
    @State private var lines: [AttributedString] = []
    @State private var bannerShown = false
    @State private var expanded = false
    @State private var answer: Bool?
    @State private var signingIn = false
    @State private var macFound = false
    @State private var prompt = ""
    @State private var sent = ""
    @State private var replied = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            switch step {
            case .demo: demo.transition(.opacity)
            case .mac: mac.transition(.opacity)
            case .notifications: notifications.transition(.opacity)
            case .task: task.transition(.opacity)
            case .chief: chief.transition(.opacity)
            }
        }
        .sheet(isPresented: $signingIn) {
            VStack(spacing: 0) {
                Text("Sign in").font(theme.type.sheetTitle).padding(.top, 28)
                Text("Use the account you use on your Mac.").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
                    .padding(.top, 4).padding(.bottom, 22)
                ProtoSignIn { _ in
                    signingIn = false
                    animate(theme.motion.gentle) { step = .mac }
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                Spacer(minLength: 0)
            }
            .presentationDetents([.height(400)])
            .presentationCornerRadius(38)
            .presentationBackground(theme.colors.sheet.color)
        }
        .protoToast($toast)
    }

    // The terminal plays an agent's run; then its request drops in from the top.
    private var demo: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProtoMark(size: 30)
                Text("cmux").font(theme.type.welcomeWordmark)
            }
            .padding(.top, 12)
            .opacity(bannerShown ? 0 : 1)
            terminal.padding(.top, 104)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(answer == nil ? "An agent needs your OK." : answer == true ? "That was cmux." : "You stayed in charge.")
                    .font(theme.type.welcomeTitle)
                    .contentTransition(.opacity)
                Text(answer == nil ? "It’s waiting on your Mac. Answer it from here." : "Agents run on your Mac. You keep the final say, from your pocket.")
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .contentTransition(.opacity)
            }
            if answer != nil {
                ProtoButton(title: "Set up cmux", primary: true) { signingIn = true }
                    .padding(.top, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { banner }
        .task { await play() }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 10, height: 10) }
                Text("\(Proto.mac) · api-server").font(theme.type.legal).foregroundStyle(Color.white.opacity(0.45)).padding(.leading, 6)
            }
            .padding(.bottom, 12)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).transition(.opacity)
            }
        }
        .font(theme.type.codeBody)
        .foregroundStyle(Color(white: 0.92))
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .padding(16)
        .background(Color(white: 0.055), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var banner: some View {
        VStack(spacing: 8) {
            Button {
                theme.haptics.impactLight()
                animate(theme.motion.snappy) { expanded = true }
            } label: { ProtoPermissionBanner() }
            .buttonStyle(.cmuxPressFill)
            .disabled(answer != nil)
            if expanded && answer == nil {
                VStack(spacing: 0) {
                    actionRow("Allow once", "checkmark") { decide(true) }
                    Divider()
                    actionRow("Always allow", "checkmark.seal") { decide(true) }
                    Divider()
                    actionRow("Deny", "xmark", destructive: true) { decide(false) }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 12)
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else if bannerShown && answer == nil {
                Label("Tap to answer", systemImage: "arrow.up")
                    .font(theme.type.meta.weight(.semibold))
                    .foregroundStyle(theme.colors.neutralOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.colors.neutralAccent, in: .capsule)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .offset(y: bannerShown && answer == nil ? 0 : -220)
        .opacity(bannerShown && answer == nil ? 1 : 0)
    }

    private func actionRow(_ title: LocalizedStringKey, _ symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol)
            }
            .font(theme.type.body)
            .foregroundStyle(destructive ? theme.colors.dangerText : theme.colors.label)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.cmuxPressFill)
    }

    private func line(_ text: String, _ tint: Color? = nil) -> AttributedString {
        var value = AttributedString(text)
        if let tint { value.foregroundColor = tint }
        return value
    }

    private func play() async {
        let script: [(String, Color?, Int)] = [
            ("~/api-server  claude", Color(hex: "#2AA0F9"), 400),
            ("› fix the failing auth tests", nil, 500),
            ("  Reading tests/auth.test.ts", Color(white: 0.6), 600),
            ("  Editing src/auth/session.ts  +12 −3", nil, 600),
            ("  npm test  48 passed", Color(hex: "#30D158"), 700),
            ("  ● Waiting for you to approve git push", Color(hex: "#FFD60A"), 700),
        ]
        for (text, tint, delay) in script {
            await pause(delay)
            animate(theme.motion.snap) { lines.append(line(text, tint)) }
        }
        await pause(500)
        theme.haptics.impactLight()
        animate(theme.motion.snappy) { bannerShown = true }
    }

    private func decide(_ allow: Bool) {
        allow ? theme.haptics.success() : theme.haptics.warning()
        animate(theme.motion.smooth) {
            answer = allow
            expanded = false
            lines[lines.count - 1] = allow ? line("  ✓ Approved from iPhone", Color(hex: "#30D158")) : line("  ✕ Denied from iPhone", Color(hex: "#FF453A"))
            lines.append(allow ? line("  Pushed to origin/feat-onboarding", Color(hex: "#30D158")) : line("  Stopped. Nothing was pushed.", Color(white: 0.6)))
        }
    }

    private var mac: some View {
        VStack(spacing: 0) {
            Spacer()
            ProtoMacArt(lit: macFound)
            ProtoMacStatus(found: macFound).padding(.top, 24)
            Text(macFound ? "Connected" : "Open cmux on your Mac")
                .font(theme.type.welcomeTitle)
                .contentTransition(.opacity)
                .padding(.top, 28)
            Text(macFound ? "Its terminals, agents and browser tabs are now on your phone." : "Sign in there as \(Proto.user). It shows up here by itself.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.top, 8)
                .frame(maxWidth: 300)
            Spacer()
            if macFound {
                ProtoButton(title: "Continue", primary: true) { animate { step = .notifications } }
                    .transition(.opacity)
            } else {
                TextCTA("Get cmux for Mac") { animate { toast = "Link sent to \(Proto.user)" } }
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 16)
        .task {
            await pause(2600)
            theme.haptics.success()
            animate(theme.motion.snappy) { macFound = true }
        }
    }

    private var notifications: some View {
        VStack(spacing: 0) {
            Spacer()
            ProtoPushes().rise()
            Text("Answer them anywhere").font(theme.type.welcomeTitle).padding(.top, 30).rise(0.06)
            Text("Like you just did. Only when an agent asks, finishes or gets stuck.")
                .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).multilineTextAlignment(.center)
                .frame(maxWidth: 310).padding(.top, 8).rise(0.12)
            Spacer()
            ProtoButton(title: "Turn on notifications", primary: true) {
                Task { _ = await askForNotifications(); animate { step = .task } }
            }
            TextCTA("Not now") { animate { step = .task } }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 8)
    }

    private var task: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What should your agents do first?").font(theme.type.welcomeTitle).padding(.top, 60).rise()
            Text("Chief starts it on \(Proto.mac).").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).padding(.top, 8).rise(0.06)
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Proto.starters, id: \.self) { starter in
                        ProtoChip(title: starter, selected: prompt == starter) { prompt = starter }
                    }
                }
                .padding(.horizontal, theme.metrics.sideMargin)
            }
            .padding(.horizontal, -theme.metrics.sideMargin)
            .padding(.bottom, 10)
            .rise(0.12)
            ProtoComposer(text: $prompt) {
                sent = prompt
                animate { step = .chief }
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 10)
    }

    private var chief: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Chief").font(theme.type.screenTitle)
                Text(Proto.mac).font(theme.type.legal).foregroundStyle(theme.colors.label2)
            }
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 10) {
                Text(sent)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if replied {
                    Text("On it. I started Claude Code in api-server and I’ll tap you when it needs you.").rise()
                    ProtoTaskCard().rise(0.1)
                } else {
                    ProtoTypingDots()
                }
            }
            .font(theme.type.body)
            .padding(.horizontal, theme.metrics.sideMargin)
            .padding(.top, 24)
            Spacer()
        }
        .task {
            await pause(1300)
            animate { replied = true }
        }
    }
}

// MARK: - 2 · Thread

/// Chief onboards you in its own conversation: each step is a message, and its
/// control sits inline in the thread or as a quick reply above the composer.
private struct ProtoThread: View {
    private enum Item: Identifiable, Equatable {
        case chief(String), user(String), signIn, mac(found: Bool), pushes, task, plan
        var id: String {
            switch self {
            case .chief(let text): "c\(text)"
            case .user(let text): "u\(text)"
            case .signIn: "signIn"
            case .mac: "mac"
            case .pushes: "pushes"
            case .task: "task"
            case .plan: "plan"
            }
        }
    }

    private enum Replies: Equatable { case hidden, notifications, starters, plan }

    @State private var items: [Item] = []
    @State private var typing = false
    @State private var replies = Replies.hidden
    @State private var composerOn = false
    @State private var text = ""
    @State private var maxTier = false
    @State private var buying = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ProtoMark(size: 34)
                Text("Chief").font(theme.type.rowSubtitle.weight(.semibold))
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Divider() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in row(item).id(item.id).transition(.opacity.combined(with: .offset(y: 8))) }
                        if typing { ProtoTypingDots().id("typing") }
                    }
                    .font(theme.type.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                // The newest message stays in view when the reply bar under it grows or shrinks.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .safeAreaBar(edge: .bottom, spacing: 0) { footer }
                .onChange(of: items.count) { scrollToEnd(proxy) }
                .onChange(of: typing) { scrollToEnd(proxy) }
                .onChange(of: replies) { scrollToEnd(proxy) }
            }
        }
        .task { await opening() }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        animate(theme.motion.smooth) { proxy.scrollTo(typing ? "typing" : items.last?.id, anchor: .bottom) }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .chief(let text):
            Text(text).frame(maxWidth: 320, alignment: .leading)
        case .user(let text):
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .signIn:
            ProtoSignIn { method in Task { await signedIn(method) } }
                .padding(12)
                .background(theme.colors.surface, in: .rect(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(theme.colors.separator, lineWidth: 0.5))
        case .mac(let found):
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(theme.type.rowTitle)
                    .frame(width: 36, height: 36).background(theme.colors.fill, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(found ? Proto.mac : "Waiting for your Mac").font(theme.type.rowSubtitle.weight(.semibold))
                    HStack(spacing: 6) {
                        if found { Circle().fill(theme.colors.success).frame(width: 7, height: 7) }
                        Text(found ? "Connected" : "Open cmux there and sign in").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                    }
                }
                Spacer()
                if found {
                    Image(systemName: "checkmark.circle.fill").font(theme.type.sheetTitle).foregroundStyle(theme.colors.success)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    CmuxSpinner(tint: theme.colors.label2.color)
                }
            }
            .padding(14)
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
        case .pushes:
            ProtoPushes(radius: 22)
        case .task:
            ProtoTaskCard()
        case .plan:
            plan
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Plan", selection: $maxTier) {
                Text("Pro").tag(false)
                Text("Max").tag(true)
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(maxTier ? "$239.99" : "$59.99").font(theme.type.heroTitle).monospacedDigit().contentTransition(.numericText())
                Text("/ month, billed yearly").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            Text(maxTier ? "Up to 5 Cloud VMs · 80 vCPUs, 160 GB RAM" : "Up to 5 Cloud VMs · 20 vCPUs, 40 GB RAM")
                .font(theme.type.meta).foregroundStyle(theme.colors.label2)
            ProtoButton(title: maxTier ? "Try Max" : "Try Pro", primary: true, isLoading: buying) {
                buying = true
                Task {
                    await pause(900)
                    theme.haptics.success()
                    animate {
                        items.removeAll { $0 == .plan }
                        replies = .hidden
                        items.append(.user("Subscribed"))
                    }
                    await say("You’re on \(maxTier ? "Max" : "Pro"). Your agents can now keep going on Cloud VMs.")
                }
            }
        }
        .padding(14)
        .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: 26, style: .continuous))
        .animation(theme.motion.snap.animation.unlessReduceMotion, value: maxTier)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch replies {
                    case .hidden: EmptyView()
                    case .notifications:
                        ProtoChip(title: "Turn on notifications") { Task { await notifications(on: true) } }
                        ProtoChip(title: "Not now") { Task { await notifications(on: false) } }
                    case .starters:
                        ForEach(Proto.starters, id: \.self) { starter in ProtoChip(title: starter) { text = starter } }
                    case .plan:
                        ProtoChip(title: "Maybe later") { Task { await laterPlan() } }
                    }
                }
                .padding(.horizontal, 12)
                .animation(theme.motion.smooth.animation.unlessReduceMotion, value: replies)
            }
            .frame(height: replies == .hidden ? 0 : 40)
            ProtoComposer(text: $text, placeholder: composerOn ? "Ask Chief to do something" : "Chief is setting you up") {
                Task { await sendTask() }
            }
            .disabled(!composerOn)
            .opacity(composerOn ? 1 : 0.55)
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func say(_ text: String, think: Int = 700) async {
        animate(theme.motion.snap) { typing = true }
        await pause(think)
        animate(theme.motion.smooth) {
            typing = false
            items.append(.chief(text))
        }
        await pause(120)
    }

    private func show(_ item: Item, think: Int = 400) async {
        animate(theme.motion.snap) { typing = true }
        await pause(think)
        animate(theme.motion.smooth) {
            typing = false
            items.append(item)
        }
        await pause(120)
    }

    private func opening() async {
        await say("Hi, I’m Chief.", think: 600)
        await say("I run coding agents on your Mac and keep track of them, so you can steer from here.", think: 900)
        await show(.signIn)
    }

    private func signedIn(_ method: SignInMethod) async {
        animate {
            items.removeAll { $0 == .signIn }
            items.append(.user(method.title.isEmpty ? "Signed in" : "Continue with \(method.title)"))
        }
        await say("Welcome, Aziz.", think: 500)
        await say("Now open cmux on your Mac and sign in there as \(Proto.user). I’ll spot it.", think: 800)
        await show(.mac(found: false))
        await pause(2600)
        theme.haptics.success()
        animate(theme.motion.snappy) {
            if let index = items.firstIndex(of: .mac(found: false)) { items[index] = .mac(found: true) }
        }
        await say("Got it. When an agent needs you, I tap you on the shoulder. It looks like this:", think: 900)
        await show(.pushes)
        animate { replies = .notifications }
    }

    private func notifications(on: Bool) async {
        animate { replies = .hidden }
        if on { _ = await askForNotifications() }
        animate { items.append(.user(on ? "Turn on notifications" : "Not now")) }
        await say(on ? "Done. You’ll only hear from me when it matters." : "No problem. You can turn them on later in Settings.", think: 600)
        await say("What should I start on?", think: 700)
        animate {
            composerOn = true
            replies = .starters
        }
    }

    private func sendTask() async {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        text = ""
        animate {
            replies = .hidden
            items.append(.user(task))
        }
        await say("On it. Claude Code is starting in api-server.", think: 700)
        await show(.task, think: 300)
        await say("One more thing, if you want it: on a plan, agents keep going when your Mac sleeps.", think: 1100)
        await show(.plan, think: 400)
        animate { replies = .plan }
    }

    private func laterPlan() async {
        animate {
            items.removeAll { $0 == .plan }
            replies = .hidden
            items.append(.user("Maybe later"))
        }
        await say("Anytime, in Settings. I’ll let you know when that task needs you.", think: 600)
    }
}

// MARK: - 3 · Home First

/// One tap from Welcome to Home. Setup is a card with three items you finish in
/// any order; it folds away when all three are done.
private struct ProtoHomeFirst: View {
    private enum Sheet: Identifiable { case mac, notifications; var id: Self { self } }

    @State private var signedIn = false
    @State private var moreOptions = false
    @State private var busy = false
    @State private var macDone = false
    @State private var notificationsDone = false
    @State private var taskDone = false
    @State private var cardGone = false
    @State private var sheet: Sheet?
    @State private var macFound = false
    @State private var text = ""
    @State private var toast: String?
    @FocusState private var composerFocused: Bool

    private var doneCount: Int { [macDone, notificationsDone, taskDone].filter { $0 }.count }

    var body: some View {
        ZStack {
            if signedIn { home.transition(.opacity) } else { welcome.transition(.opacity) }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .mac: macSheet
                case .notifications: notificationsSheet
                }
            }
            .presentationDetents([.medium])
            .presentationCornerRadius(38)
            .presentationBackground(theme.colors.sheet.color)
        }
        .protoToast($toast)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ProtoMark(size: 84).rise()
            Text("Your Mac’s agents,\nin your pocket.")
                .font(theme.type.welcomeTitle).multilineTextAlignment(.center).padding(.top, 26).rise(0.06)
            Text("Steer terminals, agents and Chief from anywhere.")
                .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).multilineTextAlignment(.center).padding(.top, 10).rise(0.12)
            Spacer()
            VStack(spacing: theme.metrics.ctaWelcomeGap) {
                ProtoButton(title: "Continue with Apple", method: .apple, primary: true, isLoading: busy) { go() }
                if moreOptions {
                    ProtoButton(title: "Continue with Google", method: .google) { go() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    ProtoButton(title: "Continue with GitHub", method: .github) { go() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    ProtoButton(title: "Continue with email", method: .emailCode(Proto.user)) { go() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    TextCTA("More options") { animate(theme.motion.smooth) { moreOptions = true } }
                }
            }
            .rise(0.18)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 12)
    }

    private func go() {
        busy = true
        theme.haptics.impactLight()
        Task {
            await pause(650)
            animate(theme.motion.gentle) { signedIn = true }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Home").font(theme.type.heroTitle)
                    Spacer()
                    Image(systemName: "person.crop.circle").font(theme.type.sheetTitle).foregroundStyle(theme.colors.label2)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 8)
                .padding(.bottom, 14)
                if !cardGone {
                    setupCard.padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
                }
                section("Macs")
                group {
                    homeRow(symbol: "laptopcomputer", title: macDone ? Proto.mac : "No Mac yet",
                            detail: macDone ? "Online · 3 workspaces" : "Connect one to see its workspaces", dim: !macDone, online: macDone)
                }
                if macDone {
                    section("Workspaces")
                    group {
                        homeRow(symbol: "terminal", title: "api-server", detail: taskDone ? "Claude Code · running" : "Idle", running: taskDone)
                        Divider().padding(.leading, 62)
                        homeRow(symbol: "terminal", title: "cmux", detail: "Idle")
                        Divider().padding(.leading, 62)
                        homeRow(symbol: "terminal", title: "web", detail: "Idle")
                    }
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 16)
        }
        .background(theme.colors.bgGrouped.color.ignoresSafeArea())
        // A bar the list scrolls under (with the system's soft edge), not a layer drawn on top of its rows.
        .safeAreaBar(edge: .bottom, spacing: 0) { dock }
    }

    private var setupCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(theme.colors.fillSelected, lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(doneCount) / 3)
                        .stroke(theme.colors.label, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                .animation(theme.motion.smooth.animation.unlessReduceMotion, value: doneCount)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Get set up").font(theme.type.rowTitle.weight(.semibold))
                    Text("\(doneCount) of 3 done").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(16)
            setupRow("laptopcomputer", "Connect your Mac", "So your agents have somewhere to run", done: macDone) { sheet = .mac }
                .accessibilityIdentifier("proto.setup.mac")
            Divider().padding(.leading, 62)
            setupRow("bell", "Turn on notifications", "Know when an agent needs you", done: notificationsDone) { sheet = .notifications }
                .accessibilityIdentifier("proto.setup.notifications")
            Divider().padding(.leading, 62)
            setupRow("sparkles", "Give Chief a first task", "Type it below", done: taskDone) { composerFocused = true }
                .accessibilityIdentifier("proto.setup.task")
        }
        .background(theme.colors.surface, in: .rect(cornerRadius: theme.metrics.groupRadius, style: .continuous))
    }

    private func setupRow(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(theme.type.rowTitle)
                    .frame(width: 34, height: 34).background(theme.colors.fill, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(theme.type.rowTitle.weight(.medium))
                        .foregroundStyle(done ? theme.colors.label2 : theme.colors.label)
                        .strikethrough(done, color: theme.colors.label3.color)
                    Text(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill").font(theme.type.sheetTitle).foregroundStyle(theme.colors.success)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Image(systemName: "chevron.right").font(theme.type.meta.weight(.semibold)).foregroundStyle(theme.colors.label3)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.cmuxPressFill)
        .disabled(done)
        .foregroundStyle(theme.colors.label)
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title).font(theme.type.meta.weight(.semibold)).foregroundStyle(theme.colors.label2)
            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 8)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(theme.colors.surface, in: .rect(cornerRadius: theme.metrics.groupRadius, style: .continuous))
            .padding(.horizontal, 16)
    }

    private func homeRow(symbol: String, title: String, detail: String, dim: Bool = false, online: Bool = false, running: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(theme.type.rowTitle)
                .frame(width: 34, height: 34).background(theme.colors.fill, in: .rect(cornerRadius: 10, style: .continuous))
                .opacity(dim ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(theme.type.rowTitle.weight(.medium)).foregroundStyle(dim ? theme.colors.label2 : theme.colors.label)
                HStack(spacing: 6) {
                    if online { Circle().fill(theme.colors.success).frame(width: 7, height: 7) }
                    Text(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
            }
            Spacer()
            if running { CmuxSpinner(tint: theme.colors.label2.color) }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
    }

    private var dock: some View {
        VStack(spacing: 10) {
            if !taskDone {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Proto.starters, id: \.self) { starter in
                            ProtoChip(title: starter) { text = starter; composerFocused = true }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            ProtoComposer(text: $text, focused: $composerFocused) { sendTask() }
                .overlay(RoundedRectangle(cornerRadius: theme.metrics.composerRadius, style: .continuous)
                    .strokeBorder(Color(hex: "#2AA0F9").opacity(composerFocused ? 0.5 : 0), lineWidth: 2))
                .animation(theme.motion.snap.animation.unlessReduceMotion, value: composerFocused)
                .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func sendTask() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        composerFocused = false
        theme.haptics.success()
        animate(theme.motion.snappy) { taskDone = true }
        toast = "Chief started it on your Mac"
        finishIfDone()
    }

    private func finishIfDone() {
        guard doneCount == 3 else { return }
        Task {
            await pause(2600)
            animate(theme.motion.smooth) { cardGone = true }
            toast = "You’re all set"
        }
    }

    private var macSheet: some View {
        VStack(spacing: 0) {
            ProtoMacArt(lit: macFound, width: 190).padding(.top, 34)
            Text(macFound ? "Connected" : "Open cmux on your Mac").font(theme.type.sheetTitle).contentTransition(.opacity).padding(.top, 22)
            Text(macFound ? Proto.mac : "Sign in there as \(Proto.user). It shows up here by itself.")
                .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).multilineTextAlignment(.center)
                .contentTransition(.opacity).frame(maxWidth: 290).padding(.top, 6)
            ProtoMacStatus(found: macFound).padding(.top, 20)
            Spacer()
            TextCTA("Get cmux for Mac") { toast = "Link sent to \(Proto.user)" }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .task {
            await pause(2400)
            theme.haptics.success()
            animate(theme.motion.snappy) { macFound = true }
            await pause(1000)
            sheet = nil
            animate(theme.motion.snappy) { macDone = true }
            finishIfDone()
        }
    }

    private var notificationsSheet: some View {
        VStack(spacing: 0) {
            ProtoPushes(radius: 22).padding(.top, 28)
            Text("Know when an agent needs you").font(theme.type.sheetTitle).padding(.top, 20)
            Text("Requests, finished tasks and Chief. Press and hold one to answer it.")
                .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).multilineTextAlignment(.center)
                .frame(maxWidth: 300).padding(.top, 6)
            Spacer()
            ProtoButton(title: "Turn on notifications", primary: true) {
                Task {
                    sheet = nil
                    _ = await askForNotifications()
                    animate(theme.motion.snappy) { notificationsDone = true }
                    finishIfDone()
                }
            }
            .accessibilityIdentifier("proto.notifications.allow")
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 12)
    }
}

// MARK: - 4 · One Scene

/// One illustration stays put while the words under it change: the Mac and
/// the phone link, a request drops onto the phone, the Mac's screen runs the task.
private struct ProtoOneScene: View {
    private enum Step: Int { case welcome, signIn, connect, notify, task, running }

    @State private var step = Step.welcome
    @State private var linked = false
    @State private var lit = false
    @State private var notified = false
    @State private var termLines: [String] = []
    @State private var picked: String?
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            scene.frame(height: 360)
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { index in
                    Capsule().fill(theme.colors.fillSelected)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.colors.label)
                                .frame(maxWidth: step.rawValue >= index ? .infinity : 0, alignment: .leading)
                        }
                        .frame(height: 4)
                }
            }
            .animation(theme.motion.smooth.animation.unlessReduceMotion, value: step)
            .padding(.horizontal, theme.metrics.sideMargin)
            .padding(.top, 12)
            panel
                .id(step)
                .transition(.opacity.combined(with: .offset(y: 8)))
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 20)
        }
        .protoToast($toast)
    }

    private var scene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Color(hex: "#2AA0F9").opacity(linked ? 0.22 : 0.10), .clear],
                               center: .bottom, startRadius: 10, endRadius: w * 0.9)
                    .animation(theme.motion.gentle.animation.unlessReduceMotion, value: linked)
                // The Mac
                VStack(spacing: 0) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.colors.surfaceRaised)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(lit ? AnyShapeStyle(Proto.gradient) : AnyShapeStyle(theme.colors.fillSelected))
                            .padding(7)
                        if lit && termLines.isEmpty {
                            CmuxMark().fill(Color.white).frame(width: 22, height: 32).transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                        if !termLines.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(termLines, id: \.self) { Text($0).lineLimit(1).transition(.opacity) }
                            }
                            .font(theme.type.diffGutter)
                            .foregroundStyle(Color(white: 0.92))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                            .background(Color(white: 0.055), in: .rect(cornerRadius: 6, style: .continuous))
                            .padding(7)
                            .transition(.opacity)
                        }
                    }
                    .frame(width: w * 0.6, height: w * 0.39)
                    UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 7, bottomTrailing: 7), style: .continuous)
                        .fill(theme.colors.surfaceRaised).frame(width: w * 0.74, height: 9)
                }
                .offset(x: w * 0.05, y: 40)
                // The link
                Path { path in
                    path.move(to: CGPoint(x: w * 0.62, y: 270))
                    path.addCurve(to: CGPoint(x: w * 0.36, y: 40 + w * 0.39 + 14),
                                  control1: CGPoint(x: w * 0.46, y: 272), control2: CGPoint(x: w * 0.36, y: 250))
                }
                .trim(from: 0, to: linked ? 1 : 0)
                .stroke(Proto.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 7]))
                .animation(.easeInOut(duration: 1.1).unlessReduceMotion, value: linked)
                if linked {
                    HStack(spacing: 6) {
                        Circle().fill(theme.colors.success).frame(width: 7, height: 7)
                        Text(Proto.mac).font(theme.type.legal.weight(.semibold))
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(theme.colors.surface, in: .capsule)
                    .overlay(Capsule().strokeBorder(theme.colors.separator, lineWidth: 0.5))
                    .offset(x: w * 0.08, y: 296)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                // The phone
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.1))
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.colors.bg).padding(4)
                    Capsule().fill(Color.black).frame(width: 34, height: 10).padding(.top, 9)
                    ProtoMark(size: 36).frame(maxHeight: .infinity)
                    if notified {
                        ProtoPermissionBanner().frame(width: 96).padding(.top, 26)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(width: 108, height: 220)
                .offset(x: w * 0.62, y: 120)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var panel: some View {
        switch step {
        case .welcome:
            stepText("Your Mac, in your pocket.", "Terminals, agents and Chief, live on your phone.") {
                ProtoButton(title: "Get started", primary: true) { advance(.signIn) }
            }
        case .signIn:
            VStack(alignment: .leading, spacing: 16) {
                Text("Sign in").font(theme.type.sheetTitle)
                ProtoSignIn { _ in Task { await connect() } }
            }
        case .connect:
            stepText(linked ? "Connected" : "Open cmux on your Mac",
                     linked ? "Everything running on that Mac is now one tap away." : "Sign in there as \(Proto.user). We’ll find it.") {
                if linked {
                    ProtoButton(title: "Continue", primary: true) { advance(.notify); animate(theme.motion.snappy) { notified = true } }
                } else {
                    ProtoMacStatus(found: false).frame(maxWidth: .infinity)
                }
            }
        case .notify:
            stepText("We’ll tap you when it matters", "When an agent asks, finishes or gets stuck. Press and hold to answer.") {
                ProtoButton(title: "Turn on notifications", primary: true) {
                    Task { _ = await askForNotifications(); advance(.task) }
                }
                TextCTA("Not now") { advance(.task) }
            }
        case .task, .running:
            VStack(alignment: .leading, spacing: 0) {
                Text("Give it a first task").font(theme.type.welcomeTitle)
                Text("It starts on your Mac, up there.").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).padding(.top, 6)
                FlowChips(items: Proto.starters, picked: picked) { run($0) }.padding(.top, 18)
                Spacer(minLength: 12)
                if step == .running {
                    ProtoButton(title: "Open Home", primary: true) { toast = "Home: 1 agent running" }
                        .transition(.opacity)
                }
            }
        }
    }

    private func stepText<Actions: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(theme.type.welcomeTitle)
            Text(detail).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).padding(.top, 8)
            Spacer(minLength: 12)
            VStack(spacing: 4, content: actions)
        }
    }

    private func advance(_ next: Step) {
        animate { step = next }
    }

    private func connect() async {
        advance(.connect)
        await pause(2200)
        theme.haptics.success()
        animate(theme.motion.gentle) {
            linked = true
            lit = true
        }
    }

    private func run(_ task: String) {
        guard picked == nil else { return }
        picked = task
        animate(theme.motion.snappy) { notified = false }
        Task {
            let script = ["~/api-server  claude", "› \(task.lowercased())", "Reading the project…", "Planning 3 steps", "Working ▍"]
            for line in script {
                await pause(450)
                animate(theme.motion.snap) { termLines.append(line) }
            }
            theme.haptics.success()
            advance(.running)
        }
    }
}

/// Chips that wrap onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]
    let picked: String?
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                ProtoChip(title: item, selected: picked == item) { pick(item) }
                    .disabled(picked != nil)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - 5 · Three Screens

/// The fewest decisions: a two-line promise, then three numbered screens of one
/// sentence each, then a live timer for the task you just started.
private struct ProtoThreeScreens: View {
    private enum Step: Int { case welcome, mac, notifications, task, running }

    @State private var step = Step.welcome
    @State private var signingIn = false
    @State private var busy = false
    @State private var macFound = false
    @State private var text = ""
    @State private var started = Date()
    @State private var toast: String?
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var midSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 92

    var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome.transition(.opacity)
            case .mac, .notifications, .task: numbered.transition(.opacity)
            case .running: running.transition(.opacity)
            }
        }
        .sheet(isPresented: $signingIn) {
            VStack(spacing: 18) {
                Text("Sign in").font(theme.type.sheetTitle).padding(.top, 28)
                ProtoSignIn { _ in
                    signingIn = false
                    animate(theme.motion.gentle) { step = .mac }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .presentationDetents([.height(360)])
            .presentationCornerRadius(38)
            .presentationBackground(theme.colors.sheet.color)
        }
        .protoToast($toast)
    }

    private var big: Font { .system(size: bigSize, weight: .bold) }
    private var mid: Font { .system(size: midSize, weight: .bold) }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProtoMark(size: 44).padding(.top, 16).rise()
            Spacer()
            Text("Agents on\nyour Mac.").font(big).tracking(-1).rise(0.06)
            Text("Answers on\nyour phone.").font(big).tracking(-1).foregroundStyle(theme.colors.label3).rise(0.14)
            VStack(spacing: 4) {
                ProtoButton(title: "Continue with Apple", method: .apple, primary: true, isLoading: busy) {
                    busy = true
                    Task { await pause(650); animate(theme.motion.gentle) { step = .mac } }
                }
                TextCTA("Other ways to sign in") { signingIn = true }
            }
            .padding(.top, 30)
            .rise(0.2)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 12)
    }

    private var numbered: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { index in
                    Capsule().fill(theme.colors.fillSelected)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.colors.label).frame(maxWidth: step.rawValue >= index ? .infinity : 0, alignment: .leading)
                        }
                        .frame(height: 3)
                }
            }
            .animation(theme.motion.smooth.animation.unlessReduceMotion, value: step)
            .padding(.top, 10)
            HStack {
                Text("0\(step.rawValue) / 03").font(theme.type.meta.weight(.semibold)).monospacedDigit().foregroundStyle(theme.colors.label2)
                Spacer()
                Button("Skip") { skip() }
                    .font(theme.type.rowSubtitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label2)
                    .buttonStyle(.cmuxPressFill)
            }
            .padding(.top, 16)
            Group {
                switch step {
                case .mac: macScreen
                case .notifications: notificationsScreen
                default: taskScreen
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .offset(y: 10)))
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 12)
    }

    private var macScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open cmux on\nyour Mac.").font(mid).tracking(-0.6).padding(.top, 22)
            Text("Sign in there as \(Proto.user). It appears here.").font(theme.type.body).foregroundStyle(theme.colors.label2).padding(.top, 12)
            Spacer()
            HStack(spacing: 12) {
                if macFound {
                    Image(systemName: "checkmark.circle.fill").font(theme.type.sheetTitle).foregroundStyle(theme.colors.success)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    Text(Proto.mac).font(theme.type.body.weight(.semibold))
                } else {
                    CmuxSpinner(tint: theme.colors.label2.color)
                    Text("Looking for your Mac").font(theme.type.body)
                }
                Spacer()
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Divider() }
            Group {
                if macFound {
                    ProtoButton(title: "Continue", primary: true) { animate { step = .notifications } }
                } else {
                    TextCTA("Get cmux for Mac") { toast = "Link sent to \(Proto.user)" }.frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 16)
        }
        .task {
            await pause(2400)
            theme.haptics.success()
            animate(theme.motion.snappy) { macFound = true }
        }
    }

    private var notificationsScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Only when\nit matters.").font(mid).tracking(-0.6).padding(.top, 22)
            Text("A request, a finished task, a word from Chief.").font(theme.type.body).foregroundStyle(theme.colors.label2).padding(.top, 12)
            Spacer()
            ProtoPushes()
            Spacer()
            ProtoButton(title: "Turn on notifications", primary: true) {
                Task { _ = await askForNotifications(); animate { step = .task } }
            }
        }
    }

    private var taskScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("First task?").font(mid).tracking(-0.6).padding(.top, 22)
            TextField(Proto.starters[0], text: $text, axis: .vertical)
                .font(.system(size: midSize * 0.85, weight: .semibold))
                .lineLimit(2...5)
                .padding(.top, 16)
            FlowChips(items: Array(Proto.starters.dropFirst()), picked: nil) { text = $0 }.padding(.top, 16)
            Spacer()
            ProtoButton(title: "Start", primary: true) { start() }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(theme.colors.success).frame(width: 10, height: 10)
                Text("Running").font(theme.type.body.weight(.semibold))
            }
            .rise()
            TimelineView(.periodic(from: started, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.system(size: timerSize, weight: .thin))
                    .monospacedDigit()
                    .tracking(-3)
                    .contentTransition(.numericText())
            }
            .padding(.top, 6)
            .rise(0.06)
            Text(text.isEmpty ? Proto.starters[0] : text).font(theme.type.body.weight(.semibold)).padding(.top, 14).rise(0.12)
            Text("Claude Code · api-server · \(Proto.mac)").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).padding(.top, 4).rise(0.16)
            Spacer()
            ProtoButton(title: "Go to Home", primary: true) { toast = "Home: 1 agent running" }.rise(0.22)
            Text("You can close the app. We’ll tap you when it needs you.")
                .font(theme.type.meta).foregroundStyle(theme.colors.label2)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 10)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.bottom, 12)
    }

    private func skip() {
        switch step {
        case .mac: animate { step = .notifications }
        case .notifications: animate { step = .task }
        default: start()
        }
    }

    private func start() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { text = Proto.starters[0] }
        started = Date()
        theme.haptics.success()
        animate(theme.motion.gentle) { step = .running }
    }
}
#endif
