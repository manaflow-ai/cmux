import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `remote.tmux.*` control commands.
///
/// The command bodies live in CmuxControlSocket's ``ControlRemoteTmuxWorker``;
/// this file supplies the live-state seam (``ControlRemoteTmuxReading``) the
/// worker reads through, plus the one worker-thread→async bridge that lets the
/// synchronous `nonisolated` socket-worker lane drive the `async` worker.
///
/// ## Why the seam, not a direct call
///
/// `ControlRemoteTmuxWorker` is in a package that must not import the app
/// target, where the `remote.tmux.*` commands reach the `@MainActor`
/// `RemoteTmuxController` (via `AppDelegate.shared`) and the
/// `RemoteTmuxController.isEnabled` beta flag. ``ControlRemoteTmuxReading``
/// inverts that: the package owns the protocol, ``TerminalControllerRemoteTmuxReading``
/// conforms it, hopping to the main actor inside each member to fetch the
/// controller (throwing `unreachable("app not ready")` when absent, exactly as
/// the legacy bodies did) and call its `async` methods, then mapping the
/// app-side value types into the package's Sendable transfer twins.
extension TerminalController {
    /// Drives the package ``ControlRemoteTmuxWorker`` for one decoded
    /// `remote.tmux.*` request from the synchronous socket-worker lane, blocking
    /// the worker thread until the async worker completes. This single semaphore
    /// is the worker-thread→async bridge (the legacy bodies blocked the worker
    /// lane on `v2VmCall`'s semaphore). The worker only returns `nil` for
    /// non-`remote.tmux.*` methods, which the dispatcher never routes here, so a
    /// `nil` result reports the same encode-failure response the legacy plumbing
    /// produced for an impossible payload.
    nonisolated func runRemoteTmuxWorker(_ request: ControlRequest) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ControlCallResult?
        Task {
            result = await controlRemoteTmuxWorker.handle(request)
            semaphore.signal()
        }
        semaphore.wait()
        guard let result else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlRemoteTmuxReading`` with no live `TerminalController` state:
/// the bodies reach only `RemoteTmuxController.isEnabled` (a static
/// UserDefaults read) and `AppDelegate.shared?.remoteTmuxController`, so the
/// conformer is a plain `Sendable` value.
///
/// Each member hops to the `@MainActor` to fetch the controller and call its
/// `async` methods, reproducing the legacy `MainActor.run(body:)` controller
/// fetch (and its `unreachable("app not ready")` throw on a missing controller)
/// followed by the controller's own main-actor-isolated work. The returned
/// app-side value types are mapped into the package's Sendable transfer twins.
struct TerminalControllerRemoteTmuxReading: ControlRemoteTmuxReading {
    func isEnabled() -> Bool {
        RemoteTmuxController.isEnabled
    }

    func listSessions(host: ControlRemoteTmuxHost) async throws -> [ControlRemoteTmuxSession] {
        guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let sessions = try await controller.listSessions(host: Self.host(host))
        return sessions.map { session in
            ControlRemoteTmuxSession(
                id: session.id,
                name: session.name,
                windowCount: session.windowCount,
                attached: session.attached,
                createdUnix: session.createdUnix
            )
        }
    }

    func attachControlStreamWhenReady(
        host: ControlRemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) async throws -> [String]? {
        guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        return try await controller.attachControlStreamWhenReady(
            host: Self.host(host),
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
    }

    func mirrorHost(host: ControlRemoteTmuxHost) async throws {
        guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        try await controller.mirrorHost(host: Self.host(host))
    }

    func mirrorHostInNewWindow(
        host: ControlRemoteTmuxHost,
        activateWindow: Bool
    ) async throws -> ControlRemoteTmuxAttachOutcome {
        guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let outcome = try await controller.mirrorHostInNewWindow(
            host: Self.host(host),
            activateWindow: activateWindow
        )
        switch outcome {
        case .mirrored(let windowId):
            return .mirrored(windowID: windowId.uuidString)
        case .authRequired(let sshArgv):
            return .authRequired(sshArgv: sshArgv)
        }
    }

    func detach(host: ControlRemoteTmuxHost, sessionName: String) async throws {
        try await MainActor.run {
            guard let controller = AppDelegate.shared?.remoteTmuxController else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            controller.detach(host: Self.host(host), sessionName: sessionName)
        }
    }

    func stateSnapshot(
        host: ControlRemoteTmuxHost,
        sessionName: String
    ) async -> ControlRemoteTmuxStateSnapshot? {
        let snapshot: RemoteTmuxControlConnection.Snapshot? = await MainActor.run {
            AppDelegate.shared?.remoteTmuxController
                .connection(host: Self.host(host), sessionName: sessionName)?
                .snapshot()
        }
        guard let snapshot else { return nil }
        return ControlRemoteTmuxStateSnapshot(
            started: snapshot.started,
            enterReceived: snapshot.enterReceived,
            exited: snapshot.exited,
            sessionId: snapshot.sessionId,
            windowCount: snapshot.windowCount,
            windowIDs: snapshot.windowIDs,
            paneOutputByteCounts: snapshot.paneOutputByteCounts,
            totalOutputBytes: snapshot.totalOutputBytes,
            recentEvents: snapshot.recentEvents
        )
    }

    /// Rebuilds the app-side `RemoteTmuxHost` (and its ControlMaster-socket / argv
    /// machinery) from the socket-validated package value.
    private static func host(_ host: ControlRemoteTmuxHost) -> RemoteTmuxHost {
        RemoteTmuxHost(
            destination: host.destination,
            port: host.port,
            identityFile: host.identityFile
        )
    }
}
