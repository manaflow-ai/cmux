internal import Foundation

/// The worker-lane RPC handler for the `auth.*` control commands, lifted from
/// `TerminalController.socketWorkerV2Response`.
///
/// Owns the command logic for `auth.status`, `auth.sign_in_url`,
/// `auth.begin_sign_in`, and `auth.sign_out`, reaching the live auth coordinator
/// strictly through the ``AuthStatusReading`` seam and returning a typed
/// ``ControlCallResult``. It does no socket I/O and never imports the app
/// target.
///
/// ## Isolation
///
/// `Sendable` and `async`, NOT `@MainActor`: these commands run on the
/// nonisolated socket-worker lane (`runsOnSocketWorker`), where they must not
/// block the cooperative pool waiting on main-actor work. The legacy bodies
/// bridged the worker thread to the main actor with `DispatchSemaphore` +
/// `Task { @MainActor }` (and `v2MainSync` for `auth.sign_in_url`). Here that
/// bridge is replaced by the ``AuthStatusReading`` async surface: each handler
/// awaits the seam, which hops to the main actor internally. The single
/// remaining worker-thread→async bridge lives in the app's worker-lane
/// dispatcher. The wire payloads are byte-identical to the legacy ones (see
/// ``ControlAuthStatus`` for the per-field mapping).
public struct ControlAuthWorker: Sendable {
    /// The live auth-state seam. Injected at construction (the app conforms it
    /// over its `authCoordinator` / `browserSignInFlow`).
    private let reading: any AuthStatusReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The auth-state seam to read/drive.
    public init(reading: any AuthStatusReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is an `auth.*` worker-lane command,
    /// returning the typed result; returns `nil` for any other method so the
    /// caller can fall through to the next handler.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned `auth.*` method.
    public func handle(_ request: ControlRequest) async -> ControlCallResult? {
        switch request.method {
        case "auth.status":
            // Legacy: awaited coordinator bootstrap, then read the snapshot and
            // reported timedOut:false.
            await reading.awaitBootstrapped()
            let snapshot = await reading.statusSnapshot()
            return .ok(statusPayload(snapshot, timedOut: false))
        case "auth.sign_in_url":
            // Legacy: `result["url"] = signInURL` only when non-nil; otherwise
            // an empty object.
            var fields: [String: JSONValue] = [:]
            if let url = await reading.signInURL() {
                fields["url"] = .string(url)
            }
            return .ok(.object(fields))
        case "auth.begin_sign_in":
            // Legacy: `(request.params["timeout_seconds"] as? Double) ?? 300`,
            // where params were Foundation-bridged — reproduce via foundationObject.
            let timeoutSeconds = (request.params["timeout_seconds"]?.foundationObject as? Double) ?? 300
            let signedIn = await reading.beginSignIn(timeoutSeconds: timeoutSeconds)
            let snapshot = await reading.statusSnapshot()
            return .ok(statusPayload(snapshot, timedOut: !signedIn))
        case "auth.sign_out":
            await reading.signOut()
            let snapshot = await reading.statusSnapshot()
            return .ok(statusPayload(snapshot, timedOut: false))
        default:
            return nil
        }
    }

    /// Builds the `auth.status`-shaped payload from a snapshot, folding in the
    /// per-command `timedOut` flag, exactly as the legacy
    /// `v2AuthStatusPayload(timedOut:)` did. A `nil` snapshot (no coordinator)
    /// renders the fixed "not signed in" object the legacy code produced in its
    /// `guard let coordinator` else branch.
    private func statusPayload(_ snapshot: ControlAuthStatus?, timedOut: Bool) -> JSONValue {
        guard let snapshot else {
            return .object([
                "signed_in": .bool(false),
                "is_restoring_session": .bool(false),
                "is_loading": .bool(false),
                "timed_out": .bool(timedOut),
            ])
        }
        var status: [String: JSONValue] = [
            "signed_in": .bool(snapshot.signedIn),
            "is_restoring_session": .bool(snapshot.isRestoringSession),
            "is_loading": .bool(snapshot.isLoading),
            "timed_out": .bool(timedOut),
        ]
        if let user = snapshot.user {
            var userDict: [String: JSONValue] = ["id": .string(user.id)]
            if let email = user.email { userDict["email"] = .string(email) }
            if let name = user.displayName { userDict["display_name"] = .string(name) }
            status["user"] = .object(userDict)
        }
        if let teamID = snapshot.selectedTeamID {
            status["selected_team_id"] = .string(teamID)
        }
        if !snapshot.teams.isEmpty {
            status["teams"] = .array(snapshot.teams.map { team in
                var dict: [String: JSONValue] = [
                    "id": .string(team.id),
                    "display_name": .string(team.displayName),
                ]
                if let slug = team.slug { dict["slug"] = .string(slug) }
                return .object(dict)
            })
        }
        return .object(status)
    }
}
