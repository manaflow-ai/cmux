public import CmuxNextDaemon
import Foundation
import os

private let grantsLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// cmux Remote's Accessibility and Screen Recording, as one fresh probe read them
/// (docs/cmux-remote.md, Permissions).
public nonisolated struct CmuxRemoteGrants: Sendable, Equatable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// The host process that holds them, when the status names it.
    public var hostPID: Int32?

    public init(accessibility: Bool, screenRecording: Bool, hostPID: Int32? = nil) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.hostPID = hostPID
    }
}

/// Computer Use setup's view of cmux Remote: its grants and the person's requests for them. The
/// host runs each request itself, so macOS names cmux Remote in the prompt; a second request
/// opens the System Settings pane instead (macOS prompts once per identity).
extension CmuxRemoteService {
    /// A fresh probe (`refresh`, which also restarts a worker that started without a grant that is
    /// now on). Nil when this build has no cmux Remote or the host does not answer.
    public func refreshGrants() async -> CmuxRemoteGrants? {
        guard started else { return nil }
        do {
            return Self.grants(try await call("refresh"))
        } catch {
            grantsLogger.notice("cmux Remote grants not read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Asks macOS for one grant in the host (the person's click only).
    public func requestGrant(screenRecording: Bool) async {
        await grantCall("request", screenRecording: screenRecording)
    }

    /// Opens the System Settings pane of one grant (the person's click only).
    public func openGrantSettings(screenRecording: Bool) async {
        await grantCall("open_settings", screenRecording: screenRecording)
    }

    private func grantCall(_ method: String, screenRecording: Bool) async {
        guard started else { return }
        let permission = screenRecording ? "screen-recording" : "accessibility"
        do {
            _ = try await call(method, .object(["permission": .string(permission)]))
        } catch {
            grantsLogger.notice("cmux Remote \(method, privacy: .public) \(permission, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The grants of a host status (`permissions`), or of a daemon `remote-host-status` (`host.permissions`).
    public nonisolated static func grants(_ status: CmuxNextDaemon.JSONValue) -> CmuxRemoteGrants? {
        let host = status["permissions"] == nil ? status["host"] : status
        guard let permissions = host?["permissions"], let accessibility = permissions["accessibility"]?.boolValue,
              let screenRecording = permissions["screen_recording"]?.boolValue else { return nil }
        return CmuxRemoteGrants(accessibility: accessibility, screenRecording: screenRecording,
                                hostPID: host?["pid"]?.doubleValue.map { Int32($0) })
    }
}
