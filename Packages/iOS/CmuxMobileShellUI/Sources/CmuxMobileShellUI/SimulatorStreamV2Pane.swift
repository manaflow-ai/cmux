#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSimulatorStream
import CmuxMobileSupport
import CmuxSimulatorStreamKit
import SwiftUI
import UIKit

/// Simulator streaming v2: hardware-decoded video over a dedicated lane.
///
/// The pane owns its whole session: appear attaches, disappear detaches, and
/// every recovery path is the store's single reattach flow. There is no
/// shared stream state anywhere else in the shell, which is what makes a
/// remount or route change unable to strand a session.
struct SimulatorStreamV2Pane: View {
    let panelID: String
    let workspaceID: String
    let access: SimulatorStreamV2Access
    let isTransportReady: Bool
    let supportsDeviceSwitching: Bool
    let listDevices: @MainActor () async -> [MobileSimulatorDeviceDescriptor]
    let selectDevice: @MainActor (String) async -> Bool
    let supportsRecover: Bool
    let recover: @MainActor () async -> Bool

    @State private var store: SimulatorStreamV2Store?
    @State private var pendingText = ""
    @State private var devices: [MobileSimulatorDeviceDescriptor] = []
    @State private var deviceFetchTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    /// Pane-level stall timer: the connecting/reconnecting overlays swap
    /// every retry cycle, so a per-overlay timer would reset on each flip
    /// and the refresh escape hatch would never appear. Tracked here, it
    /// survives phase churn and reveals once the wait has genuinely stalled.
    @State private var stallRevealTask: Task<Void, Never>?
    @State private var stallRevealed = false
    @AppStorage("cmux.simulatorStream.quality")
    private var qualityRaw = SimStreamQualityPreset.default.rawValue
    @FocusState private var textFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var quality: SimStreamQualityPreset {
        SimStreamQualityPreset(rawValue: qualityRaw) ?? .default
    }

    var body: some View {
        ZStack {
            Color.black
            if let store {
                SimStreamDisplayRepresentable(store: store)
                    .accessibilityIdentifier("SimulatorStreamV2Video")
                if hostNeedsRecovery(store.hostStatus) {
                    recoveryOverlay
                } else {
                    overlay(for: store.phase)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .overlay(alignment: .topTrailing) {
            if let store, case .streaming = store.phase {
                liveStatusPill
                    .padding(.top, 12)
                    .padding(.trailing, 12)
            }
        }
        .accessibilityIdentifier("SimulatorStreamV2Pane")
        .onAppear {
            let store =
                self.store
                ?? SimulatorStreamV2Store(
                    panelID: panelID,
                    opener: access.opener,
                    transportReady: access.transportReady,
                    maximumLongSidePixels: quality.maximumLongSidePixels
                )
            self.store = store
            store.activate()
        }
        .task {
            refreshDevices()
        }
        .onDisappear {
            deviceFetchTask?.cancel()
            deviceFetchTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            stallRevealTask?.cancel()
            stallRevealTask = nil
        }
        .onChange(of: isStalled, initial: true) { _, stalled in
            if stalled {
                guard stallRevealTask == nil else { return }
                stallRevealTask = Task {
                    // Intentional bounded progressive-disclosure delay past
                    // the lifecycle's 4s backoff ceiling; cancellation is
                    // wired to leaving the stalled state and to disappear.
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    stallRevealed = true
                }
            } else {
                stallRevealTask?.cancel()
                stallRevealTask = nil
                stallRevealed = false
            }
        }
        .onChange(of: qualityRaw) { _, _ in
            store?.setQuality(maximumLongSidePixels: quality.maximumLongSidePixels)
        }
        .onDisappear {
            store?.deactivate()
        }
        .onChange(of: isTransportReady) { _, ready in
            store?.noteTransportReady(ready)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store?.appBackgrounded()
            case .active:
                store?.appForegrounded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func overlay(for phase: SimStreamViewerPhase) -> some View {
        switch phase {
        case .idle, .connecting:
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.waiting", defaultValue: "Waiting for Simulator"),
                detail: L10n.string(
                    "mobile.simulatorStream.waitingDetail",
                    defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "iphone",
                showsProgress: true,
                refresh: .afterStall
            )
            .accessibilityIdentifier("SimulatorStreamV2Placeholder")
        case .reconnecting:
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.stalled", defaultValue: "Reconnecting to Simulator"),
                detail: L10n.string(
                    "mobile.simulatorStream.stalledDetail",
                    defaultValue: "The video feed stalled. Restoring the stream."),
                symbol: "arrow.triangle.2.circlepath",
                showsProgress: true,
                refresh: .afterStall
            )
            .accessibilityIdentifier("SimulatorStreamV2ReconnectingOverlay")
        case .unavailable(let detail):
            // Refresh reattaches the stream, which cannot help while the Mac
            // has simulator panes disabled, so that one state stays inert.
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.unavailable", defaultValue: "Simulator Unavailable"),
                detail: Self.unavailableDetailText(detail),
                symbol: "iphone.slash",
                showsProgress: false,
                refresh: detail == "simulator_disabled" ? .hidden : .immediate
            )
            .accessibilityIdentifier("SimulatorStreamV2UnavailableOverlay")
        case .streaming, .stopped:
            EmptyView()
        }
    }

    /// Mirrors the Mac pane's Reconnect states: a crash-fused worker, a
    /// failed session, or a vanished device never self-heals, so the frozen
    /// frame needs a host-side recover, not another lane retry.
    private func hostNeedsRecovery(_ status: SimStreamHostStatus?) -> Bool {
        status == .workerCrashed || status == .failed || status == .deviceUnavailable
    }

    /// Whether the viewer is waiting on frames with no terminal verdict:
    /// the states whose overlays earn the delayed refresh escape hatch.
    private var isStalled: Bool {
        guard let store, !hostNeedsRecovery(store.hostStatus) else { return false }
        switch store.phase {
        case .idle, .connecting, .reconnecting:
            return true
        case .streaming, .unavailable, .stopped:
            return false
        }
    }

    /// One shared refresh path for every entrypoint (menu item, overlay
    /// buttons, recovery overlay): the exact equivalent of the Mac pane's
    /// Reconnect button. Always asks the Mac to recover the session
    /// (`mobile.simulator.recover` runs the same `recover()` that button
    /// does), then rebuilds the local viewer through the store's single
    /// reattach flow. Unconditional on purpose: the phone cannot always see
    /// which Mac-side state wedged the pane (renderer stopped, stale
    /// worker), and refresh is an explicit user action, so a brief restart
    /// of a healthy stream is acceptable. Single-flight: extra taps while a
    /// refresh is in flight are dropped, so recover RPCs never overlap.
    private func refreshStream() {
        guard let store, refreshTask == nil else { return }
        refreshTask = Task {
            if supportsRecover {
                _ = await recover()
            }
            store.refresh()
            refreshTask = nil
        }
    }

    /// The Mac's simulator worker crashed and fused (or failed): the frame
    /// on screen is frozen and no lane retry can revive it. Mirror the Mac
    /// pane's Reconnect affordance so the fix is one tap away on the phone.
    private var recoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
            statusCard(
                title: L10n.string(
                    "mobile.simulatorStream.needsRecovery",
                    defaultValue: "Simulator Needs Recovery"),
                detail: L10n.string(
                    "mobile.simulatorStream.needsRecoveryDetail",
                    defaultValue:
                        "The Simulator session on the Mac stopped and is showing its last frame."),
                symbol: "exclamationmark.triangle",
                tint: .orange,
                showsProgress: refreshTask != nil
            ) {
                if supportsRecover {
                    overlayRefreshButton(
                        title: L10n.string(
                            "mobile.simulatorStream.recover", defaultValue: "Recover"),
                        systemImage: "arrow.clockwise",
                        identifier: "SimulatorStreamV2RecoverButton")
                }
            }
        }
        .accessibilityIdentifier("SimulatorStreamV2RecoveryOverlay")
    }

    /// Host detail strings are protocol tokens, never user-facing prose:
    /// known tokens map to localized copy and anything else falls back to
    /// the generic message, so raw host text is never rendered.
    private static func unavailableDetailText(_ detail: String) -> String {
        switch detail {
        case "superseded":
            return L10n.string(
                "mobile.simulatorStream.supersededDetail",
                defaultValue: "Another device took over this Simulator stream.")
        case "panel_closed", "panel_not_found":
            return L10n.string(
                "mobile.simulatorStream.panelClosedDetail",
                defaultValue: "The Simulator pane was closed on the Mac.")
        case "simulator_disabled":
            return L10n.string(
                "mobile.simulatorStream.disabledDetail",
                defaultValue: "Simulator panes are disabled on the Mac.")
        default:
            return L10n.string(
                "mobile.simulatorStream.unavailableDetail",
                defaultValue: "The Mac closed this Simulator stream.")
        }
    }

    /// How a status overlay offers the manual refresh escape hatch.
    private enum OverlayRefresh {
        /// No refresh affordance (refreshing cannot change the state).
        case hidden
        /// Refresh is available right away (terminal states).
        case immediate
        /// Refresh appears only once the wait has clearly stalled (the
        /// pane-level `stallRevealed` timer), so the routine sub-second
        /// connect never flashes a button.
        case afterStall
    }

    private func statusOverlay(
        title: String,
        detail: String,
        symbol: String,
        showsProgress: Bool,
        refresh: OverlayRefresh
    ) -> some View {
        ZStack {
            Color.black.opacity(0.58)
            statusCard(
                title: title,
                detail: detail,
                symbol: symbol,
                tint: .accentColor,
                showsProgress: showsProgress
            ) {
                switch refresh {
                case .hidden:
                    EmptyView()
                case .immediate:
                    overlayRefreshButton()
                case .afterStall:
                    if stallRevealed {
                        overlayRefreshButton()
                    }
                }
            }
        }
        // A dead stream has nothing useful under the overlay, so swallowing
        // touches costs nothing and keeps the refresh button tappable.
        .allowsHitTesting(refresh != .hidden)
    }

    @ViewBuilder
    private func statusCard<Actions: View>(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        showsProgress: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .offset(y: 37)
                        .accessibilityLabel(
                            L10n.string(
                                "mobile.connection.reconnecting",
                                defaultValue: "Reconnecting"))
                }
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .padding(24)
        .foregroundStyle(.primary)
    }

    private var liveStatusPill: some View {
        Label(
            L10n.string("mobile.connection.connected", defaultValue: "Connected"),
            systemImage: "circle.fill"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: Capsule())
        .accessibilityIdentifier("SimulatorStreamV2LiveStatus")
    }

    @ViewBuilder
    private func overlayRefreshButton(
        title: String = L10n.string("mobile.simulatorStream.refresh", defaultValue: "Refresh"),
        systemImage: String = "arrow.clockwise",
        identifier: String = "SimulatorStreamV2RefreshButton"
    ) -> some View {
        Button {
            refreshStream()
        } label: {
            if refreshTask != nil {
                ProgressView()
                    .controlSize(.small)
                Text(
                    L10n.string(
                        "mobile.connection.reconnecting", defaultValue: "Reconnecting"))
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(refreshTask != nil)
        .accessibilityIdentifier(identifier)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField(
                    L10n.string("mobile.simulatorStream.textPlaceholder", defaultValue: "Text"),
                    text: $pendingText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.send)
                .focused($textFocused)
                .font(.body)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .mobileGlassField(cornerRadius: 16)
                .onSubmit { submitText() }
                .accessibilityIdentifier("SimulatorStreamV2TextField")

                chromeButton(
                    systemImage: "paperplane.fill",
                    label: L10n.string("mobile.simulatorStream.sendText", defaultValue: "Send Text"),
                    identifier: "SimulatorStreamV2SendTextButton",
                    disabled: pendingText.isEmpty
                ) { submitText() }
                .mobileGlassCircle()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    hardwareButton(
                        .home, systemImage: "house",
                        label: L10n.string("mobile.simulatorStream.home", defaultValue: "Home"),
                        identifier: "SimulatorStreamV2HomeButton")
                    hardwareButton(
                        .lock, systemImage: "lock",
                        label: L10n.string("mobile.simulatorStream.lock", defaultValue: "Lock"),
                        identifier: "SimulatorStreamV2LockButton")

                    Menu {
                        menuButton(
                            .appSwitcher, systemImage: "rectangle.stack",
                            label: L10n.string(
                                "mobile.simulatorStream.appSwitcher", defaultValue: "App Switcher"))
                        menuButton(
                            .volumeUp, systemImage: "speaker.plus",
                            label: L10n.string(
                                "mobile.simulatorStream.volumeUp", defaultValue: "Volume Up"))
                        menuButton(
                            .volumeDown, systemImage: "speaker.minus",
                            label: L10n.string(
                                "mobile.simulatorStream.volumeDown", defaultValue: "Volume Down"))
                        menuButton(
                            .siri, systemImage: "waveform",
                            label: L10n.string("mobile.simulatorStream.siri", defaultValue: "Siri"))
                        // Manual escape hatch in every state, including a frozen
                        // frame the phase machine still believes is streaming.
                        Button {
                            refreshStream()
                        } label: {
                            Label(
                                L10n.string(
                                    "mobile.simulatorStream.refreshSimulator",
                                    defaultValue: "Refresh Simulator"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .accessibilityIdentifier("SimulatorStreamV2RefreshMenuItem")
                        qualityMenu
                        if supportsDeviceSwitching, !devices.isEmpty {
                            deviceMenu
                        }
                        // Menu content materializes when the menu opens, so this
                        // refreshes the device inventory (and stale checkmarks from
                        // Mac-side switches) right before the user can reach the
                        // Switch Simulator submenu.
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onAppear { refreshDevices() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .mobileGlassCircle()
                    .accessibilityLabel(
                        L10n.string("mobile.simulatorStream.moreButtons", defaultValue: "More Buttons")
                    )
                    .accessibilityIdentifier("SimulatorStreamV2MoreButtons")
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)
        }
        // Neutral chrome: the hardware-button icons read as controls, not
        // links, so they must not pick up the app accent color.
        .tint(.primary)
    }

    private var qualityMenu: some View {
        Picker(
            L10n.string("mobile.simulatorStream.quality", defaultValue: "Stream Quality"),
            selection: $qualityRaw
        ) {
            Text(L10n.string("mobile.simulatorStream.qualityHigh", defaultValue: "High"))
                .tag(SimStreamQualityPreset.high.rawValue)
            Text(
                L10n.string(
                    "mobile.simulatorStream.qualityBalanced", defaultValue: "Balanced")
            )
            .tag(SimStreamQualityPreset.balanced.rawValue)
            Text(
                L10n.string(
                    "mobile.simulatorStream.qualityDataSaver", defaultValue: "Data Saver")
            )
            .tag(SimStreamQualityPreset.dataSaver.rawValue)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("SimulatorStreamV2QualityPicker")
    }

    private var deviceMenu: some View {
        Menu {
            // Rows live-update in place: entering the submenu re-fetches, so
            // an inventory raced ahead of the menu-open refresh corrects
            // itself, and stale selects already fail safe on the host
            // (unknown devices reject, the current device is a no-op).
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { refreshDevices() }
            ForEach(devices) { device in
                Button {
                    switchDevice(to: device.udid)
                } label: {
                    if device.isSelected {
                        Label(deviceLabel(device), systemImage: "checkmark")
                    } else {
                        Text(deviceLabel(device))
                    }
                }
                .disabled(device.isSelected)
            }
        } label: {
            Label(
                L10n.string(
                    "mobile.simulatorStream.switchSimulator", defaultValue: "Switch Simulator"),
                systemImage: "iphone.gen3"
            )
        }
        .accessibilityIdentifier("SimulatorStreamV2DeviceMenu")
    }

    private func deviceLabel(_ device: MobileSimulatorDeviceDescriptor) -> String {
        "\(device.name) · \(device.runtimeName)"
    }

    /// One owned fetch at a time; a superseded fetch's result is discarded
    /// so a slow older response can never overwrite a newer inventory.
    private func refreshDevices() {
        guard supportsDeviceSwitching else { return }
        deviceFetchTask?.cancel()
        deviceFetchTask = Task {
            let fetched = await listDevices()
            guard !Task.isCancelled else { return }
            devices = fetched
        }
    }

    private func switchDevice(to udid: String) {
        deviceFetchTask?.cancel()
        deviceFetchTask = Task {
            _ = await selectDevice(udid)
            let fetched = await listDevices()
            guard !Task.isCancelled else { return }
            devices = fetched
        }
    }

    private func chromeButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func hardwareButton(
        _ button: SimStreamHardwareButton,
        systemImage: String,
        label: String,
        identifier: String
    ) -> some View {
        chromeButton(
            systemImage: systemImage, label: label, identifier: identifier, disabled: false
        ) {
            store?.sendButton(button)
        }
        .mobileGlassCircle()
    }

    private func menuButton(
        _ button: SimStreamHardwareButton, systemImage: String, label: String
    ) -> some View {
        Button {
            store?.sendButton(button)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func submitText() {
        let text = pendingText
        pendingText = ""
        store?.sendText(text)
    }
}

private struct SimStreamDisplayRepresentable: UIViewRepresentable {
    let store: SimulatorStreamV2Store

    func makeUIView(context: Context) -> SimStreamDisplayView {
        let view = SimStreamDisplayView()
        view.isUserInteractionEnabled = true
        view.onTouchEvent = { [weak store] event in
            store?.send(event)
        }
        store.bindPresenter(SimStreamViewPresenter(view: view))
        return view
    }

    func updateUIView(_ uiView: SimStreamDisplayView, context: Context) {}
}
#endif
