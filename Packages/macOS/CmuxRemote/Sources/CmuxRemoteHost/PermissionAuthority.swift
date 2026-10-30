// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
public import CmuxRemoteWire
import CoreGraphics
public import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "permissions")

/// The grants as one fresh process read them.
public struct PermissionSnapshot: Sendable, Equatable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// When the probe ran (wall clock, for status only).
    public var checkedAt: Date

    public func granted(_ permission: RemotePermission) -> Bool {
        permission == .accessibility ? accessibility : screenRecording
    }

    public var fields: [String: Any] {
        ["accessibility": accessibility, "screen_recording": screenRecording,
         "checked_at": Int(checkedAt.timeIntervalSince1970 * 1000)]
    }
}

/// The host's grants (docs/cmux-remote.md, Permissions). Status comes from a
/// fresh `cmux-remote probe` process, because a process that has run since a
/// grant can keep the old Screen Recording answer and a new one cannot.
/// Requests run in this process, so macOS names cmux Remote in its prompt.
public final class PermissionAuthority: Sendable {
    /// Runs the probe; the real one spawns this executable, tests replace it.
    let probe: @Sendable () -> PermissionSnapshot?
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The least time between two prompts for one permission.
    static let requestInterval: TimeInterval = 30

    private struct State: Sendable {
        var last: PermissionSnapshot?
        var lastRequest: [RemotePermission: Date] = [:]
    }

    init(probe: @escaping @Sendable () -> PermissionSnapshot?) {
        self.probe = probe
    }

    var last: PermissionSnapshot? { state.withLock { $0.last } }

    /// Probes again; returns the new snapshot and whether a grant changed since the last one.
    func refresh() -> (snapshot: PermissionSnapshot?, changed: Bool) {
        let fresh = probe()
        return state.withLock { state in
            let before = state.last
            if let fresh { state.last = fresh }
            let changed = fresh.map { new in
                before.map { $0.accessibility != new.accessibility || $0.screenRecording != new.screenRecording } ?? true
            } ?? false
            return (fresh ?? before, changed)
        }
    }

    enum RequestOutcome: String, Sendable {
        case alreadyGranted = "already_granted"
        case prompted
        /// macOS will not prompt again: the Settings pane opened.
        case openedSettings = "opened_settings"
        case throttled
    }

    /// Asks macOS for `permission` (at most once per `requestInterval`); opens
    /// the System Settings pane when macOS will not show its prompt.
    @MainActor func request(_ permission: RemotePermission, now: Date = Date()) -> RequestOutcome {
        if last?.granted(permission) == true { return .alreadyGranted }
        let asked = state.withLock { state -> Bool? in
            if let previous = state.lastRequest[permission], now.timeIntervalSince(previous) < Self.requestInterval { return nil }
            defer { state.lastRequest[permission] = now }
            return state.lastRequest[permission] != nil
        }
        guard let askedBefore = asked else { return .throttled }
        let granted = switch permission {
        case .accessibility: AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !askedBefore] as CFDictionary)
        case .screenRecording: askedBefore ? CGPreflightScreenCaptureAccess() : CGRequestScreenCaptureAccess()
        }
        if granted { return .alreadyGranted }
        logger.notice("requested \(permission.rawValue, privacy: .public) again=\(askedBefore, privacy: .public)")
        // macOS prompts once per identity; a second request opens the pane where the switch is.
        guard askedBefore else { return .prompted }
        openSettings(permission)
        return .openedSettings
    }

    @MainActor func openSettings(_ permission: RemotePermission) {
        guard let url = permission.settingsURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The asynchronous open: this never waits for System Settings.
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
    }

    /// The real probe: `<this executable> probe`, which prints one JSON line and exits.
    static func processProbe(executable: String, logPath: String) -> @Sendable () -> PermissionSnapshot? {
        {
            guard let child = try? ChildProcess.spawn(executable: executable, arguments: ["probe"],
                                                      environment: ["PATH": "/usr/bin:/bin"], logPath: logPath) else { return nil }
            close(child.stdin)
            let channel = LineChannel(read: child.stdout, write: child.stdout)
            let answer = channel.readObject()
            close(child.stdout)
            var status: Int32 = 0
            while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
            guard let answer, let accessibility = answer["accessibility"] as? Bool,
                  let screenRecording = answer["screen_recording"] as? Bool else { return nil }
            return PermissionSnapshot(accessibility: accessibility, screenRecording: screenRecording, checkedAt: Date())
        }
    }

    /// The probe's body (`cmux-remote probe`): this process's own answers.
    public static func probeLine() -> Data {
        RemoteWire.line(["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()])
    }
}
