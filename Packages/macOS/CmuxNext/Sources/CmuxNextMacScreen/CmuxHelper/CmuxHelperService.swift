import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import Foundation
import os

private let helperLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-helper")

/// cmux Helper from the app (docs/cmux-helper.md): the build's one helper app (the Screen Sharing
/// helper, `<app id>.screen-sharing`) holds Screen Recording and Accessibility for Screen Sharing
/// and Computer Use, and the daemon runs the Computer Use worker in it. This app reads the
/// daemon's `helper-status`, reports the helper's grants there, and edits the worker's saved approvals.
@MainActor
public final class CmuxHelperService {
    /// This app's local daemon connection when it serves `helper-v1`, else nil.
    private let connectionSource: @MainActor () -> DaemonConnection?
    /// ``followPermissions(activation:)`` ran (once, at launch).
    private var followsAppPermissions = false

    public init(connection: @escaping @MainActor () -> DaemonConnection?) {
        connectionSource = connection
    }

    /// This app's local daemon: its connection while it serves `helper-v1`.
    public convenience init(daemon: DaemonService) {
        self.init { [weak daemon] in daemon?.supports(DaemonCapability.helper.rawValue) == true ? daemon?.connection : nil }
    }

    // MARK: Daemon

    private var connection: DaemonConnection? { connectionSource() }

    /// One daemon request on this app's own (verified) connection.
    func daemonRequest<Request: DaemonRequest>(_ request: Request) async throws -> Request.Response {
        guard let connection else { throw CmuxHelperError.unavailable }
        return try await connection.request(request, timeout: .seconds(25))
    }

    /// `helper-status`: this app's grants as reported, and the Computer Use worker's status.
    public func status() async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxHelperError.unavailable }
        return try await connection.request(HelperStatusRequest())
    }

    // MARK: The helper's grants

    /// Tells the daemon cmux Helper's grants and System Settings name (`helper-config`: nothing
    /// saved, started or stopped), which `cmux helper grants` reads. The helper answers its own
    /// grants (a short, bounded helper command); nothing is reported in a build without it.
    public func reportPermissions() async {
        guard let connection, let helper = MacScreenHelper.bundled() else { return }
        guard let grants = await helper.permissions() else { return }
        let permissions = HelperConfigRequest.Permissions(screenRecording: grants.screenRecording, accessibility: grants.accessibility)
        do {
            _ = try await connection.request(HelperConfigRequest(permissions: permissions, name: helper.app.deletingPathExtension().lastPathComponent))
        } catch {
            helperLogger.notice("cmux Helper grants not reported: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reports cmux Helper's grants at each daemon connection that serves `helper-v1` and whenever
    /// the app becomes active, since the person may have just turned one on in System Settings.
    /// Activation comes from `activation`'s existing app-active observer (no observer of its own).
    public func followPermissions(activation: MacScreenSystemShortcuts) {
        guard !followsAppPermissions else { return }
        followsAppPermissions = true
        activation.onAppActive = { [weak self] in
            // task-owner: one report per activation, bounded by the daemon request timeout.
            Task { [weak self] in await self?.reportPermissions() }
        }
        // The source reads the daemon's connection and capabilities, so a new connection wakes this.
        let connected = { @MainActor [weak self] in self?.connection.map { ObjectIdentifier($0) } }
        // task-owner: lives with the app; one report per daemon connection.
        Task { [weak self] in
            for await current in ObservationStream(connected) where current != nil {
                await self?.reportPermissions()
            }
        }
    }

    // MARK: Computer Use

    /// Forgets `appID`'s saved answer, or saves `decision` ("always" or "never") for it.
    public func editComputerUseApproval(appID: String, decision: String?) async throws {
        _ = try await daemonRequest(ComputerUseApprovalsRequest(action: decision ?? "forget", appID: appID))
    }

    /// Ends every agent session of the Computer Use worker (`revoke_sessions`): their grants end.
    public func stopComputerUseSessions() async throws {
        _ = try await daemonRequest(ComputerUseApprovalsRequest(action: "revoke_sessions"))
    }

    /// Asks for a grant in cmux Helper, the app macOS lists in System Settings.
    public func requestGrant(_ permission: String) async {
        await MacScreenHelper.requestBundledGrant(permission)
    }
}
