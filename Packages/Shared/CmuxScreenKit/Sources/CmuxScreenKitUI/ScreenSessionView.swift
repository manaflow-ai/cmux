#if os(iOS)
import CmuxScreenKit
import CmuxSpinner
import PhotosUI
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
    /// A Direct Touch / Trackpad choice in the options menu
    /// (`ScreenPreferences.inputMode`).
    public static let inputModeToggle = ScreenFeatures(rawValue: 1 << 11)
    /// An always-visible trackpad under the screen: the toolbar, the screen and
    /// the trackpad stack top to bottom, the screen fitted to the width and the
    /// trackpad filling the rest. Its notch drags down to tuck it away to a
    /// strip at the bottom edge (the screen takes the room) and up to bring it
    /// back; a tap on the notch toggles. Up by default in portrait and
    /// remembered (`ScreenPreferences.showTrackpad`); in landscape, where height
    /// is short, it starts tucked away.
    public static let trackpadOverlay = ScreenFeatures(rawValue: 1 << 12)

    /// A Paste Image button: pick a photo, and the Mac pastes it (⌘V) where
    /// its focus is. Shown only for a Mac that takes pasted images, in full control.
    public static let pasteImage = ScreenFeatures(rawValue: 1 << 13)

    public static let all: ScreenFeatures = [.shortcutsBar, .qualityMenu, .orientationLock, .fitToggle, .displayPaging, .stats,
                                             .keyboard, .sendKeysMenu, .refresh, .hideToolbar, .resumeOnForeground,
                                             .inputModeToggle, .trackpadOverlay, .pasteImage]
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
    /// The finger's vertical travel on the drawer's notch while it drags; springs back to 0.
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3, bounce: 0.1)))
    private var trackpadDrag: CGFloat = 0
    @State private var trackpadLink = ScreenTrackpadLink()
    /// The viewer's size inside the safe area, laid out as if the keyboard were down.
    @State private var containerSize = CGSize.zero
    /// How much of the bottom of the safe area the keyboard (or only its key bar,
    /// with a hardware keyboard) covers; 0 while it is down.
    @State private var keyboardOverlap: CGFloat = 0
    /// In landscape the trackpad starts tucked away (height is short there) and
    /// does not touch the remembered choice, which is for portrait.
    @State private var landscapeTrackpadOpen = false
    /// The trackpad's hint (0...1, animated once per viewer from the trackpad's first
    /// showing); nil before it starts. Kept here, so tucking, turning or reconnecting
    /// neither restarts nor ends it.
    @State private var trackpadHintProgress: Double?
    /// The hint has played through (or the pad was touched).
    @State private var trackpadHintDone = false
    /// The toolbar's measured height (with the shortcuts bar) while it shows.
    @State private var chromeHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pickedPhoto: PhotosPickerItem?
    /// Reading and preparing the picked photo, before it is sent.
    @State private var preparingPhoto = false
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
            if hasTrackpadOverlay {
                // Toolbar, screen and trackpad stack: none covers another.
                VStack(spacing: 0) {
                    if chromeVisible {
                        chrome
                            .padding(.bottom, 6)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
                    }
                    screenView
                        .ignoresSafeArea(edges: chromeVisible ? .horizontal : [.top, .horizontal])
                    if trackpadReserved > 0 { Color.clear.frame(height: trackpadReserved) }
                }
                // Laid out as if the keyboard were down (the room it takes is `keyboardOverlap`),
                // the same in every presentation.
                .background {
                    ZStack {
                        ScreenKeyboardProbe { keyboardOverlap = $0 }
                        // The viewer's size (the stack fills the room it is offered).
                        Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
                    }
                }
                .ignoresSafeArea(.keyboard)
            } else {
                screenView.ignoresSafeArea()
                if chromeVisible { chrome }
            }
            stateCard
            if hasTrackpadOverlay, case .connected = session.phase { trackpadDrawer }
            if features.contains(.pasteImage) { pasteBanner }
        }
        .background(.black)
        // Remote screens sit on black: dark chrome keeps the bar and stats legible.
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if features.contains(.orientationLock) { ScreenOrientation.shared.lock(orientation) }
        }
        .onChange(of: orientation) {
            OrientationLock.saved = orientation
            ScreenOrientation.shared.lock(orientation)
        }
        .onChange(of: scenePhase) {
            if features.contains(.resumeOnForeground), scenePhase == .active { session.resumeIfNeeded() }
        }
        .onChange(of: session.preferences.quality) { session.applyQuality() }
        .onChange(of: trackpadShown, initial: true) { startTrackpadHint() }
        // On the root, not the picker: a stall that hides the button while the picker is open keeps the pick.
        .onChange(of: pickedPhoto) { paste(pickedPhoto) }
        .onDisappear {
            if features.contains(.orientationLock) { ScreenOrientation.shared.lock(.auto) }
            session.close()
        }
    }

    private var screenView: some View {
        ScreenView(session: session, fitToDisplay: session.preferences.fitToDisplay,
                   displayPaging: features.contains(.displayPaging), keyboardVisible: $keyboardVisible,
                   inputMode: session.preferences.inputMode, trackpadLink: trackpadLink,
                   trackpadPadActive: trackpadShown)
    }

    /// The toolbar and, once connected, the Mac shortcuts under it.
    private var chrome: some View {
        VStack(spacing: 6) {
            topBar
            if features.contains(.shortcutsBar), case .connected = session.phase {
                MacShortcutsBar(session: session, shortcuts: shortcuts)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var hasMenu: Bool {
        !features.isDisjoint(with: [.qualityMenu, .orientationLock, .fitToggle, .stats, .sendKeysMenu, .refresh, .hideToolbar,
                                    .inputModeToggle])
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Close", systemImage: "xmark") {
                session.close()
                close()
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("screen.close")
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if features.contains(.stats), session.preferences.showStats, case .connected = session.phase { stats }
            }
            Spacer(minLength: 8)
            if hasMenu { optionsMenu }
            if features.contains(.pasteImage), session.supportsImagePaste, case .connected = session.phase {
                PhotosPicker(selection: $pickedPhoto, matching: .images, preferredItemEncoding: .current) {
                    Label("Paste Image", systemImage: "photo.badge.plus").labelStyle(.iconOnly)
                }
                .disabled(preparingPhoto || session.imagePaste == .sending)
                .accessibilityIdentifier("screen.pasteImage")
            }
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
            optionsItems
        } label: {
            // Icon-only on the trigger alone: on the Menu it also stripped the titles of the
            // Toggle and Picker rows inside (empty rows with only a checkmark).
            Label("Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("screen.options")
    }

    // MARK: Trackpad drawer

    private var hasTrackpadOverlay: Bool { features.contains(.trackpadOverlay) }

    private var isLandscape: Bool { containerSize.width > containerSize.height }

    /// The trackpad is up: the remembered choice (up by default) in portrait,
    /// tucked away in landscape until it is brought up there.
    private var trackpadOpen: Bool { isLandscape ? landscapeTrackpadOpen : session.preferences.showTrackpad }

    /// The software keyboard is up (more than a key bar): the trackpad goes under it
    /// and the screen reaches down to the keyboard. With only the key bar (a hardware
    /// keyboard), the trackpad rises above the bar instead.
    private var keyboardHidesTrackpad: Bool { keyboardOverlap > trackpadDrawerHeight / 2 }

    /// The trackpad is up on a connected screen (its pad drives the pointer).
    private var trackpadShown: Bool {
        guard hasTrackpadOverlay, trackpadOpen, case .connected = session.phase else { return false }
        return true
    }

    /// The notch's strip: all of the drawer that shows while it is tucked away.
    private static let trackpadPeek: CGFloat = 30
    private static let trackpadBottomPadding: CGFloat = 8

    /// The drawer's height above the bottom safe area: the notch, the pad and the padding under it.
    private var trackpadDrawerHeight: CGFloat { Self.trackpadPeek + trackpadPadHeight + Self.trackpadBottomPadding }

    /// The room kept under the screen for the drawer: as much of it as shows
    /// (all of it while up, the notch's strip while tucked away, following the
    /// finger while the notch drags), none before the screen connects or while
    /// the software keyboard covers it.
    private var trackpadReserved: CGFloat {
        guard hasTrackpadOverlay, case .connected = session.phase else { return 0 }
        if keyboardHidesTrackpad { return keyboardOverlap }
        return max(0, trackpadDrawerHeight - trackpadOffset) + keyboardOverlap
    }

    /// The pad's height: what is left under the toolbar and the screen fitted
    /// to the width, within a floor that keeps it usable and a ceiling that
    /// keeps the screen readable (lower in landscape, where height is short).
    private var trackpadPadHeight: CGFloat {
        let size = containerSize
        guard size.width > 0, size.height > 0 else { return 240 }
        // The display the screen is fitted to (one of several), else the whole frame.
        let display = trackpadLink.focusSize.width > 0 ? trackpadLink.focusSize : session.frameSize
        let aspect = display.width > 0 ? min(max(display.height / display.width, 0.4), 1) : 0.625
        let landscape = size.width > size.height
        let chrome = chromeVisible ? chromeHeight : 0
        let room = size.height - chrome - size.width * aspect - Self.trackpadPeek - Self.trackpadBottomPadding
        let floor: CGFloat = landscape ? 110 : 160
        let ceiling = max(floor, size.height * (landscape ? 0.42 : 0.6))
        return min(max(room, floor), ceiling)
    }

    /// How far the drawer travels between tucked away (notch only) and up.
    private var trackpadTravel: CGFloat { max(0, trackpadDrawerHeight - Self.trackpadPeek) }

    /// The drawer's offset below its open position: 0 up, `trackpadTravel` tucked
    /// away, in between while the notch is dragged.
    private var trackpadOffset: CGFloat {
        min(max((trackpadOpen ? 0 : trackpadTravel) + trackpadDrag, 0), trackpadTravel)
    }

    /// Starts the hint the first time the trackpad shows in this viewer. Under Reduce
    /// Motion the still hand stays until the first touch.
    private func startTrackpadHint() {
        guard trackpadShown, trackpadHintProgress == nil else { return }
        trackpadHintProgress = 0
        guard !reduceMotion else { return }
        // motion: allow one linear timeline that the hand's pose is read from; Reduce Motion draws a still hand
        withAnimation(.linear(duration: screenTrackpadHintDuration)) {
            trackpadHintProgress = 1
        } completion: {
            trackpadHintDone = true
        }
    }

    private func setTrackpad(open: Bool) {
        // Reduce Motion: the drawer moves in one frame.
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1)) {
            if isLandscape { landscapeTrackpadOpen = open } else { session.preferences.showTrackpad = open }
        }
    }

    /// The trackpad drawer: the notch, and under it the trackpad surface,
    /// above the home indicator. Tucked away, only the notch's strip shows.
    private var trackpadDrawer: some View {
        let progress = trackpadTravel > 0 ? 1 - trackpadOffset / trackpadTravel : (trackpadOpen ? 1 : 0)
        return VStack(spacing: 0) {
            trackpadHandle
            // Tucked away (and not being dragged), the pad is not drawn: it fades out as it slides
            // down and is then removed, keeping only its room under the notch, so nothing hidden can
            // take touches or show to VoiceOver.
            ZStack(alignment: .top) {
                Color.clear.frame(height: trackpadPadHeight).accessibilityHidden(true)
                if trackpadOpen || trackpadDrag != 0 {
                    trackpadContent
                        .opacity(progress)
                        .allowsHitTesting(trackpadOpen)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, Self.trackpadBottomPadding)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: trackpadOffset - (keyboardHidesTrackpad ? 0 : keyboardOverlap))
        .opacity(keyboardHidesTrackpad ? 0 : 1)
        .allowsHitTesting(!keyboardHidesTrackpad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The software keyboard covers the drawer instead of pushing it up.
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.trackpad.drawer")
        .accessibilityValue(trackpadOpen ? "open" : "closed")
    }

    /// The trackpad surface: fills the drawer under the notch.
    private var trackpadContent: some View {
        ScreenTrackpadPad(link: trackpadLink, active: trackpadOpen)
            .frame(maxWidth: .infinity)
            .frame(height: trackpadPadHeight)
            .background {
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)).accessibilityHidden(true)
            }
            // Shows what the surface is: a hand that plays at using it, until the first touch.
            .overlay {
                if !trackpadHintDone, !trackpadLink.padTouched, let progress = trackpadHintProgress {
                    ScreenTrackpadHintFrame(progress: reduceMotion ? nil : progress)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .transition(.opacity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.14)))
    }

    /// The drawer's notch: drag it down to tuck the trackpad away, up to bring it back (a tap toggles).
    private var trackpadHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: Self.trackpadPeek)
            // A 44-point target: the strip and a little above and below it.
            .contentShape(Rectangle().inset(by: -7))
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($trackpadDrag) { value, drag, _ in drag = value.translation.height }
                    .onEnded { value in
                        // Where the drag would come to rest decides: past halfway goes there.
                        let resting = (trackpadOpen ? 0 : trackpadTravel) + value.predictedEndTranslation.height
                        setTrackpad(open: resting < trackpadTravel / 2)
                    }
            )
            .onTapGesture { setTrackpad(open: !trackpadOpen) }
            .accessibilityElement(children: .ignore)
            // Not "Trackpad": that is the Input picker's row in the viewer settings.
            .accessibilityLabel("Trackpad drawer")
            .accessibilityValue(trackpadOpen ? "Shown" : "Hidden")
            .accessibilityHint("Swipe down to tuck the trackpad away, swipe up to bring it back.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setTrackpad(open: !trackpadOpen) }
            .accessibilityIdentifier("screen.trackpad.handle")
    }

    /// The viewer settings in the top bar's options menu.
    @ViewBuilder private var optionsItems: some View {
        if features.contains(.inputModeToggle) {
            Picker("Input", systemImage: session.preferences.inputMode.symbol, selection: $session.preferences.inputMode) {
                ForEach(ScreenInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
            }
            .pickerStyle(.menu)
        }
        if hasTrackpadOverlay {
            checkItem("Show Trackpad", systemImage: "rectangle.and.hand.point.up.left",
                      isOn: Binding(get: { trackpadOpen }, set: { setTrackpad(open: $0) }))
        }
        if features.contains(.fitToggle) {
            checkItem("Fit to Display", systemImage: "rectangle.dashed", isOn: $session.preferences.fitToDisplay)
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
            checkItem("Stream stats", systemImage: "gauge.with.dots.needle.33percent", isOn: $session.preferences.showStats)
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
    }

    /// An on/off item in the options menu: a Button that flips the value and shows a checkmark.
    /// A Toggle there rendered on iOS 26 as three rows (one titled, two blank), all disabled.
    private func checkItem(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: isOn.wrappedValue ? "checkmark" : systemImage)
        }
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var stats: some View {
        let s = session.stats
        let latency = s.latencyMs.map { String(format: "%.0f ms", $0) } ?? "–"
        return Text(session.pathLabel + String(format: " · %.0f fps · %.0f KB/s · ", s.fps, s.kilobytesPerSecond) + latency + " · " + s.encoding)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("screen.stats")
    }

    @ViewBuilder private var stateCard: some View {
        switch session.phase {
        case .connecting:
            card {
                CmuxSpinner()
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

    /// Reads the picked photo, prepares it off the main thread and sends it to the Mac.
    private func paste(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickedPhoto = nil
        preparingPhoto = true
        Task {
            let photo = try? await item.loadTransferable(type: Data.self)
            // task-owner: one decode and re-encode of the picked photo; its result is read below
            let prepared = await Task.detached(priority: .userInitiated) { photo.flatMap(PastedImage.init(photo:)) }.value
            preparingPhoto = false
            guard let prepared else {
                session.reportImagePasteFailure("This photo could not be read.")
                return
            }
            session.pasteImage(prepared.data, type: prepared.type)
        }
    }

    private var pasteBannerInset: CGFloat {
        guard hasTrackpadOverlay, case .connected = session.phase else { return 24 }
        return trackpadReserved + 12
    }

    /// Where the last Paste Image is: sending, pasted, or why it failed (tap to dismiss).
    @ViewBuilder private var pasteBanner: some View {
        let state: ScreenSession.ImagePaste = preparingPhoto ? .sending : session.imagePaste
        if state != .idle {
            VStack {
                Spacer()
                Button {
                    session.dismissImagePaste()
                } label: {
                    HStack(spacing: 8) {
                        switch state {
                        case .sending:
                            CmuxSpinner()
                            Text("Pasting on \(session.title)…")
                        case .pasted:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Pasted on \(session.title)")
                        case let .failed(message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(message)
                        case .idle:
                            EmptyView()
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state == .sending)
                .accessibilityIdentifier("screen.pasteImage.status")
                // Above the trackpad drawer (its notch, or all of it when up).
                .padding(.bottom, pasteBannerInset)
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
/// mode, paging between displays, the touch input model (direct or
/// trackpad, `inputMode`; nil follows `session.preferences.inputMode`) and
/// the software keyboard. Call `session.connect()` yourself.
public struct ScreenView: UIViewControllerRepresentable {
    let session: ScreenSession
    let fitToDisplay: Bool
    let displayPaging: Bool
    let inputMode: ScreenInputMode?
    let trackpadLink: ScreenTrackpadLink?
    let trackpadPadActive: Bool
    @Binding var keyboardVisible: Bool

    /// `trackpadLink` lets a trackpad overlay's pad drive this screen's pointer;
    /// `trackpadPadActive` (the overlay is open) shows the cursor the pad moves.
    public init(session: ScreenSession, fitToDisplay: Bool = true, displayPaging: Bool = true,
                keyboardVisible: Binding<Bool> = .constant(false), inputMode: ScreenInputMode? = nil,
                trackpadLink: ScreenTrackpadLink? = nil, trackpadPadActive: Bool = false) {
        self.session = session
        self.fitToDisplay = fitToDisplay
        self.displayPaging = displayPaging
        self.inputMode = inputMode
        self.trackpadLink = trackpadLink
        self.trackpadPadActive = trackpadPadActive
        _keyboardVisible = keyboardVisible
    }

    public func makeUIViewController(context: Context) -> ScreenViewController {
        let controller = ScreenViewController(session: session)
        trackpadLink?.controller = controller
        controller.onKeyboardHidden = { [keyboardVisible = $keyboardVisible] in
            // After this update pass: the binding is not written while SwiftUI updates the view.
            // task-owner: one main-actor hop that writes the binding; nothing waits on it
            Task { @MainActor in if keyboardVisible.wrappedValue { keyboardVisible.wrappedValue = false } }
        }
        controller.onFocusSize = { [weak trackpadLink] size in
            if trackpadLink?.focusSize != size { trackpadLink?.focusSize = size }
        }
        return controller
    }

    public func updateUIViewController(_ controller: ScreenViewController, context: Context) {
        controller.fitToDisplay = fitToDisplay
        controller.allowsDisplayPaging = displayPaging
        controller.inputMode = inputMode ?? session.preferences.inputMode
        controller.trackpadPadActive = trackpadPadActive
        trackpadLink?.controller = controller
        if controller.isKeyboardVisible != keyboardVisible { controller.isKeyboardVisible = keyboardVisible }
    }
}
#endif
