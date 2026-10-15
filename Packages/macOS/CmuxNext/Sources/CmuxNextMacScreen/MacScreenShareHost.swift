public import AppKit
import CmuxNextCompat
public import CmuxScreenKit
import ApplicationServices
import CoreGraphics
public import Observation
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
        /// This Mac's link could not be read from the Keychain (locked or denied).
        case linkUnavailable
    }

    public private(set) var status = Status.off
    /// A viewer's session is open (from its channel opening to its end),
    /// whatever the status says: the menu bar indicator follows this.
    public private(set) var indicatorVisible = false {
        didSet { indicator.setVisible(indicatorVisible) }
    }
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// This Mac's pairing link while sharing is on.
    public private(set) var link: URL?
    @ObservationIgnored private let store: MacScreenStore
    @ObservationIgnored private var host: ScreenStreamHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Delivers the host's events in order on the main actor.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private var termination: (any NSObjectProtocol)?
    @ObservationIgnored private let indicator = MacScreenShareIndicator()
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-host")
    /// Permission checks; tests replace them.
    @ObservationIgnored public var checkScreenRecording: () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored public var checkAccessibility: () -> Bool = { AXIsProcessTrusted() }

    public init(store: MacScreenStore) {
        self.store = store
        indicator.stopSharing = { [weak self] in self?.disconnectViewer() }
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
        if termination == nil {
            // Quitting ends the viewer's session now, so it does not wait out a WebRTC timeout.
            termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.host?.disconnectViewer() } // main-proof: observer on queue: .main
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
            // One system prompt at a time: Screen Recording first; Accessibility has its own row.
            if !screenRecordingGranted {
                requestScreenRecording()
            } else if !accessibilityGranted {
                requestAccessibility()
            }
            start()
        } else {
            stop()
        }
    }

    public func refreshPermissions() {
        screenRecordingGranted = checkScreenRecording()
        accessibilityGranted = checkAccessibility()
        if store.shareEnabled, status == .needsPermission || status == .linkUnavailable, screenRecordingGranted { start() }
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.openInBackground(url) }
    }

    /// A new link: Macs paired with the old one can no longer connect.
    public func resetLink() {
        store.resetHostPairing(name: Self.computerName)
        if store.shareEnabled {
            stop()
            start()
        }
    }

    /// Disconnect: ends the viewer's session and turns sharing off, so the
    /// viewer cannot come straight back (it would reconnect with the link).
    public func disconnectViewer() {
        host?.disconnectViewer()
        setEnabled(false)
    }

    private func start() {
        guard task == nil else { return }
        guard let pairing = store.hostPairing(name: Self.computerName) else {
            status = .linkUnavailable
            link = nil
            return
        }
        link = pairing.link
        guard screenRecordingGranted else {
            status = .needsPermission
            return
        }
        status = .starting
        let logger = logger
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        let host = ScreenStreamHost(pairing: pairing, backend: { ScreenCaptureBackend(log: log) }, log: log)
        let (events, sink) = AsyncStream.makeStream(of: ScreenStreamHost.Event.self, bufferingPolicy: .bufferingNewest(64))
        host.onEvent = { event in sink.yield(event) }
        eventTask = Task { [weak self, weak host] in
            for await event in events {
                guard let self, let host else { return }
                handle(event, from: host)
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
        eventTask?.cancel()
        eventTask = nil
        indicatorVisible = false
        status = .off
        link = nil
        logger.info("stopped sharing this Mac's screen")
    }

    private func handle(_ event: ScreenStreamHost.Event, from source: ScreenStreamHost) {
        guard source === host else { return }
        switch event {
        case .waiting: if !indicatorVisible { status = .waiting }
        case .roomLost: if !indicatorVisible { status = .roomLost }
        case .viewerConnected:
            indicatorVisible = true
            status = .viewing
        case .viewerEnded:
            indicatorVisible = false
            if case .sourceFailed = status { break }
            status = .waiting
        case let .sourceFailed(message):
            // No picture, so no control either: end the viewer's session.
            status = .sourceFailed(message)
            source.disconnectViewer()
        }
    }

    /// The Mac's name from Sharing settings (fast; no DNS).
    public static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
