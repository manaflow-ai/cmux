public import AppKit
public import CmuxScreenKit
import ApplicationServices
import CoreGraphics
import Observation
import os
import SystemConfiguration

/// Share This Mac: serves this Mac's screen to paired Macs (and the cmux
/// VNC iOS app) as a screen stream over WebRTC, through ScreenCaptureKit
/// and CGEvent. Off until a person turns it on; it stays on across
/// launches. Needs Screen Recording (the picture) and Accessibility (the
/// input) for this app. Anyone with the link can see and control this Mac.
@Observable
public final class MacScreenShareHost {
    public enum Status: Equatable {
        case off
        /// On, but Screen Recording is not granted.
        case needsPermission
        /// Joining the room.
        case starting
        /// In the room, no viewer.
        case waiting
        /// A viewer sees and controls the screen.
        case viewing
        /// The room connection dropped; retrying on its own.
        case roomLost
        /// The screen could not be captured.
        case sourceFailed(String)
    }

    public private(set) var status = Status.off
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// This Mac's pairing link while sharing is on.
    public private(set) var link: URL?
    @ObservationIgnored private let store: MacScreenStore
    @ObservationIgnored private var host: ScreenStreamHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-host")
    /// Permission checks; tests replace them.
    @ObservationIgnored public var checkScreenRecording: () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored public var checkAccessibility: () -> Bool = { AXIsProcessTrusted() }

    public init(store: MacScreenStore) {
        self.store = store
    }

    /// At launch: starts sharing if the person left it on, and rechecks
    /// permissions whenever the app becomes active (after System Settings).
    public func activate() {
        refreshPermissions()
        if activation == nil {
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() } // main-proof: observer on queue: .main
            }
        }
        if store.shareEnabled { start() }
    }

    public var isEnabled: Bool { store.shareEnabled }

    /// The person's switch. Turning it on asks macOS for Screen Recording
    /// (and Accessibility) when they are missing.
    public func setEnabled(_ enabled: Bool) {
        store.setShareEnabled(enabled)
        if enabled {
            refreshPermissions()
            if !screenRecordingGranted { requestScreenRecording() }
            if !accessibilityGranted { requestAccessibility() }
            start()
        } else {
            stop()
        }
    }

    public func refreshPermissions() {
        screenRecordingGranted = checkScreenRecording()
        accessibilityGranted = checkAccessibility()
        if store.shareEnabled, status == .needsPermission, screenRecordingGranted { start() }
    }

    public func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings(screenRecording: true) }
    }

    public func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(screenRecording: false) }
    }

    public func openSettings(screenRecording: Bool) {
        let pane = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// A new link: Macs paired with the old one can no longer connect.
    public func resetLink() {
        store.resetHostPairing(name: Self.computerName)
        if store.shareEnabled {
            stop()
            start()
        }
    }

    public func disconnectViewer() {
        host?.disconnectViewer()
    }

    private func start() {
        guard task == nil else { return }
        guard screenRecordingGranted else {
            status = .needsPermission
            link = store.hostPairing(name: Self.computerName).link
            return
        }
        let pairing = store.hostPairing(name: Self.computerName)
        link = pairing.link
        status = .starting
        let logger = logger
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        let host = ScreenStreamHost(pairing: pairing, backend: { ScreenCaptureBackend(log: log) }, log: log)
        host.onEvent = { [weak self, weak host] event in
            Task { @MainActor [weak self] in
                guard let host else { return }
                self?.handle(event, from: host)
            }
        }
        self.host = host
        task = Task.detached { await host.run() }
        logger.info("sharing this Mac's screen")
    }

    private func stop() {
        task?.cancel()
        task = nil
        host?.onEvent = nil
        host?.disconnectViewer()
        host = nil
        status = .off
        link = nil
        logger.info("stopped sharing this Mac's screen")
    }

    private func handle(_ event: ScreenStreamHost.Event, from source: ScreenStreamHost) {
        guard source === host else { return }
        switch event {
        case .waiting: if status != .viewing { status = .waiting }
        case .roomLost: if status != .viewing { status = .roomLost }
        case .viewerConnected: status = .viewing
        case .viewerEnded: status = .waiting
        case let .sourceFailed(message): status = .sourceFailed(message)
        }
    }

    /// The Mac's name from Sharing settings (fast; no DNS).
    public static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
}
