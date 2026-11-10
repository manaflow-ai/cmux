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
    /// A Trackpad button (closed by default) that opens a draggable overlay:
    /// a trackpad surface that moves the Mac's pointer, with the viewer
    /// settings inside it instead of on the screen's top bar.
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
    /// The trackpad overlay is closed until its button opens it.
    @State private var trackpadOpen = false
    @State private var trackpadPlacement = TrackpadOverlayPlacement()
    @GestureState private var trackpadDrag = CGSize.zero
    @State private var trackpadLink = ScreenTrackpadLink()
    /// The overlay's measured height, for keeping it on screen while it is dragged.
    @State private var trackpadPanelHeight: CGFloat = 280
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
            ScreenView(session: session, fitToDisplay: session.preferences.fitToDisplay,
                       displayPaging: features.contains(.displayPaging), keyboardVisible: $keyboardVisible,
                       inputMode: session.preferences.inputMode, trackpadLink: trackpadLink,
                       trackpadPadActive: trackpadShown)
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
            if hasTrackpadOverlay, case .connected = session.phase { trackpadLayer }
            if features.contains(.pasteImage) { pasteBanner }
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
        // On the root, not the picker: a stall that hides the button while the picker is open keeps the pick.
        .onChange(of: pickedPhoto) { paste(pickedPhoto) }
        .onDisappear {
            if features.contains(.orientationLock) { ScreenOrientation.shared.lock(.auto) }
            session.close()
        }
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
            // With the trackpad overlay, the viewer settings live inside it, not on the screen.
            if hasMenu, !hasTrackpadOverlay { optionsMenu }
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

    // MARK: Trackpad overlay

    private var hasTrackpadOverlay: Bool { features.contains(.trackpadOverlay) }

    /// The overlay is open on a connected screen (its pad drives the pointer).
    private var trackpadShown: Bool {
        guard hasTrackpadOverlay, trackpadOpen, case .connected = session.phase else { return false }
        return true
    }

    /// Room the overlay is kept inside, from the screen's edges.
    private static let trackpadMargin: CGFloat = 12

    /// The Trackpad button while the overlay is closed, the overlay while open.
    private var trackpadLayer: some View {
        GeometryReader { geometry in
            if trackpadOpen {
                trackpadPanel(container: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                showTrackpadButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .padding(Self.trackpadMargin)
    }

    private var showTrackpadButton: some View {
        Button {
            trackpadOpen = true
        } label: {
            Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("screen.trackpad.show")
    }

    private func trackpadPanel(container: CGSize) -> some View {
        let panel = CGSize(width: min(container.width, 380), height: trackpadPanelHeight)
        let offset = TrackpadOverlayPlacement.clamped(
            CGSize(width: trackpadPlacement.offset.width + trackpadDrag.width,
                   height: trackpadPlacement.offset.height + trackpadDrag.height),
            panel: panel, container: container, margin: 0)
        return VStack(spacing: 10) {
            trackpadHeader(panel: panel, container: container)
            ScreenTrackpadPad(link: trackpadLink)
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.18)))
            if hasMenu {
                Menu {
                    optionsItems
                } label: {
                    Label("Viewer Settings", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("screen.options")
            }
        }
        .padding(12)
        .frame(width: panel.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trackpadPanelHeight = $0 }
        .offset(offset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.trackpad.overlay")
    }

    /// The overlay's grip (drag it to move the overlay), its title and its hide button.
    private func trackpadHeader(panel: CGSize, container: CGSize) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Trackpad").font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Hide Trackpad", systemImage: "xmark.circle.fill") { trackpadOpen = false }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("screen.trackpad.hide")
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .updating($trackpadDrag) { value, drag, _ in drag = value.translation }
                .onEnded { value in
                    trackpadPlacement.offset = TrackpadOverlayPlacement.clamped(
                        CGSize(width: trackpadPlacement.offset.width + value.translation.width,
                               height: trackpadPlacement.offset.height + value.translation.height),
                        panel: panel, container: container, margin: 0)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.trackpad.grip")
    }

    /// The viewer settings: the top bar's options menu, or the trackpad overlay's.
    @ViewBuilder private var optionsItems: some View {
        if features.contains(.inputModeToggle) {
            Picker("Input", systemImage: session.preferences.inputMode.symbol, selection: $session.preferences.inputMode) {
                ForEach(ScreenInputMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
            }
            .pickerStyle(.menu)
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
                .padding(.bottom, 24)
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
