#if os(iOS)
import CmuxScreenKit
import SwiftUI

/// The parts of `ScreenSessionView` an app opts into. `.all` is the cmux
/// VNC demo app; `.minimal` is the screen with a close button and state cards.
public struct ScreenFeatures: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// One-tap Mac shortcuts under the toolbar (Spotlight, Mission Control, …).
    public static let shortcutsBar = ScreenFeatures(rawValue: 1 << 0)
    /// Stream quality in the options menu (Auto, Smooth Motion, Fixed …).
    public static let qualityMenu = ScreenFeatures(rawValue: 1 << 1)
    /// Orientation lock in the options menu (Auto-Rotate, Portrait, Landscape).
    public static let orientationLock = ScreenFeatures(rawValue: 1 << 2)
    /// A "Fit to Display" toggle in the options menu (fitted mode itself is
    /// `ScreenPreferences.fitToDisplay`, on by default).
    public static let fitToggle = ScreenFeatures(rawValue: 1 << 3)
    /// Swipe at fit (or tap the page dots) to move between displays.
    public static let displayPaging = ScreenFeatures(rawValue: 1 << 4)
    /// The live stats line (path, fps, rate, latency, codec) and its toggle.
    public static let stats = ScreenFeatures(rawValue: 1 << 5)
    /// The keyboard button (software keyboard with an Esc/Tab/arrows/⌃⌥⌘ bar).
    public static let keyboard = ScreenFeatures(rawValue: 1 << 6)
    /// A "Send" section in the options menu (⌃⌥⌦, ⌘⇥, ⌘Space, Esc).
    public static let sendKeysMenu = ScreenFeatures(rawValue: 1 << 7)
    /// "Refresh Screen" in the options menu.
    public static let refresh = ScreenFeatures(rawValue: 1 << 8)
    /// "Hide Toolbar" in the options menu (a chevron brings it back).
    public static let hideToolbar = ScreenFeatures(rawValue: 1 << 9)
    /// Reconnect when the app returns to the foreground after a drop.
    public static let resumeOnForeground = ScreenFeatures(rawValue: 1 << 10)

    public static let all: ScreenFeatures = [.shortcutsBar, .qualityMenu, .orientationLock, .fitToggle, .displayPaging, .stats,
                                             .keyboard, .sendKeysMenu, .refresh, .hideToolbar, .resumeOnForeground]
    public static let minimal: ScreenFeatures = [.displayPaging, .resumeOnForeground]
}

/// A full-screen session: the remote screen plus light chrome that stays out
/// of the way (a top bar to hide, live stats, state cards for connecting,
/// reconnecting, sign-in and errors). Pick the chrome with `features`.
///
/// Present it full screen (`.fullScreenCover`); `close` is called when the
/// user closes it, after the session is closed. With `.orientationLock`, the
/// app delegate must return `ScreenOrientation.shared.allowed`.
public struct ScreenSessionView: View {
    @Bindable var session: ScreenSession
    let features: ScreenFeatures
    let shortcuts: [MacShortcutsBar.Shortcut]
    let close: () -> Void
    @State private var keyboardVisible = false
    @State private var chromeVisible = true
    @State private var signInUser = ""
    @State private var signInPassword = ""
    @State private var orientation = OrientationLock.saved
    @Environment(\.scenePhase) private var scenePhase

    public init(session: ScreenSession, features: ScreenFeatures = .all,
                shortcuts: [MacShortcutsBar.Shortcut] = MacShortcutsBar.standard, close: @escaping () -> Void) {
        self.session = session
        self.features = features
        self.shortcuts = shortcuts
        self.close = close
    }

    public var body: some View {
        ZStack(alignment: .top) {
            ScreenView(session: session, fitToDisplay: session.preferences.fitToDisplay,
                       displayPaging: features.contains(.displayPaging), keyboardVisible: $keyboardVisible)
                .ignoresSafeArea()
            if chromeVisible {
                VStack(spacing: 6) {
                    topBar
                    if features.contains(.shortcutsBar), case .connected = session.phase {
                        MacShortcutsBar(session: session, shortcuts: shortcuts)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            stateCard
        }
        .background(.black)
        // Remote screens sit on black: dark chrome keeps the bar and stats legible.
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear { if features.contains(.orientationLock) { ScreenOrientation.shared.lock(orientation) } }
        .onChange(of: orientation) {
            OrientationLock.saved = orientation
            ScreenOrientation.shared.lock(orientation)
        }
        .onChange(of: scenePhase) {
            if features.contains(.resumeOnForeground), scenePhase == .active { session.resumeIfNeeded() }
        }
        .onChange(of: session.preferences.quality) { session.applyQuality() }
        .onDisappear {
            if features.contains(.orientationLock) { ScreenOrientation.shared.lock(.auto) }
            session.close()
        }
    }

    private var hasMenu: Bool {
        !features.isDisjoint(with: [.qualityMenu, .orientationLock, .fitToggle, .stats, .sendKeysMenu, .refresh, .hideToolbar])
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Close", systemImage: "xmark") {
                session.close()
                close()
            }
            .labelStyle(.iconOnly)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if features.contains(.stats), session.preferences.showStats, case .connected = session.phase { stats }
            }
            Spacer(minLength: 8)
            if hasMenu { optionsMenu }
            if features.contains(.keyboard) {
                Button("Keyboard", systemImage: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                    keyboardVisible.toggle()
                }
                .labelStyle(.iconOnly)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var optionsMenu: some View {
        Menu {
            if features.contains(.fitToggle) {
                Toggle("Fit to Display", systemImage: "rectangle.dashed", isOn: $session.preferences.fitToDisplay)
            }
            if features.contains(.orientationLock) {
                Picker("Orientation", systemImage: orientation.symbol, selection: $orientation) {
                    ForEach(OrientationLock.allCases) { lock in Label(lock.title, systemImage: lock.symbol).tag(lock) }
                }
                .pickerStyle(.menu)
            }
            if features.contains(.qualityMenu), session.isStream {
                Picker("Quality", systemImage: "dial.medium", selection: $session.preferences.quality) {
                    ForEach(ScreenQuality.allCases) { quality in Text(quality.title).tag(quality) }
                }
                .pickerStyle(.menu)
            }
            if features.contains(.stats) {
                Toggle("Stream stats", isOn: $session.preferences.showStats)
            }
            if features.contains(.sendKeysMenu) {
                Section("Send") {
                    Button("Control-Option-Delete", systemImage: "command") { session.tap(.deleteForward, modifiers: [.control, .option]) }
                    Button("Command-Tab", systemImage: "rectangle.stack") { session.tap(.tab, modifiers: [.command]) }
                    Button("Command-Space", systemImage: "magnifyingglass") { session.tap(.space, modifiers: [.command]) }
                    Button("Escape", systemImage: "escape") { session.tap(.escape) }
                }
            }
            if features.contains(.refresh) {
                Button("Refresh Screen", systemImage: "arrow.clockwise") { session.refresh() }
            }
            if features.contains(.hideToolbar) {
                Button("Hide Toolbar", systemImage: "chevron.up") { withAnimation { chromeVisible = false } }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
    }

    private var stats: some View {
        let s = session.stats
        let latency = s.latencyMs.map { String(format: "%.0f ms", $0) } ?? "–"
        return Text(session.pathLabel + String(format: " · %.0f fps · %.0f KB/s · ", s.fps, s.kilobytesPerSecond) + latency + " · " + s.encoding)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var stateCard: some View {
        switch session.phase {
        case .connecting:
            card {
                ProgressView()
                Text(session.isReconnecting ? "Reconnecting to \(session.title)…" : "Connecting to \(session.title)…").font(.headline)
            }
        case let .failed(message, needsSignIn):
            card {
                Image(systemName: needsSignIn ? "lock" : "exclamationmark.triangle").font(.largeTitle)
                Text(needsSignIn ? "Sign in to \(session.title)" : "Could not connect").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if needsSignIn {
                    TextField("User name (Mac only)", text: $signInUser)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $signInPassword)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }
                HStack {
                    Button("Close") {
                        session.close()
                        close()
                    }
                    .buttonStyle(.bordered)
                    Button(needsSignIn ? "Sign In" : "Try Again", action: needsSignIn ? signIn : { session.connect() })
                        .buttonStyle(.borderedProminent)
                }
            }
            .onAppear { signInUser = session.credentials.username ?? "" }
        case .ended:
            card {
                Image(systemName: "stop.circle").font(.largeTitle)
                Text("Session ended").font(.headline)
                HStack {
                    Button("Close") { close() }.buttonStyle(.bordered)
                    Button("Reconnect") { session.connect() }.buttonStyle(.borderedProminent)
                }
            }
        case .connected:
            if !chromeVisible {
                Button("Show Toolbar", systemImage: "chevron.down") { withAnimation { chromeVisible = true } }
                    .labelStyle(.iconOnly)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.top, 4)
            }
        }
    }

    private func signIn() {
        session.credentials = VNCCredentials(username: signInUser, password: signInPassword)
        session.connect()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(22)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The remote screen alone, for apps that bring their own chrome: fitted
/// mode, paging between displays, the touch input model (tap clicks, hold
/// and drag drags, two-finger tap right-clicks, two fingers scroll, pinch
/// zooms) and the software keyboard. Call `session.connect()` yourself.
public struct ScreenView: UIViewControllerRepresentable {
    let session: ScreenSession
    let fitToDisplay: Bool
    let displayPaging: Bool
    @Binding var keyboardVisible: Bool

    public init(session: ScreenSession, fitToDisplay: Bool = true, displayPaging: Bool = true,
                keyboardVisible: Binding<Bool> = .constant(false)) {
        self.session = session
        self.fitToDisplay = fitToDisplay
        self.displayPaging = displayPaging
        _keyboardVisible = keyboardVisible
    }

    public func makeUIViewController(context: Context) -> ScreenViewController {
        ScreenViewController(session: session)
    }

    public func updateUIViewController(_ controller: ScreenViewController, context: Context) {
        controller.fitToDisplay = fitToDisplay
        controller.allowsDisplayPaging = displayPaging
        if controller.isKeyboardVisible != keyboardVisible { controller.isKeyboardVisible = keyboardVisible }
    }
}
#endif
