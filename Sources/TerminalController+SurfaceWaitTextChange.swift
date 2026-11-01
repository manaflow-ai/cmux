import CmuxControlSocket
import Foundation

extension TerminalController {
    /// `surface.wait_text_change`: answers with the terminal's text once it
    /// differs from `after_revision`, or when `timeout_ms` runs out.
    ///
    /// The reply is the `surface.read_text` payload plus `revision` and
    /// `changed`. Reads go through the `surface.read_text` worker body, so
    /// selectors, errors and the relay checks are the same. Between reads the
    /// wait is parked on the terminal's PTY output stream and woken by the
    /// next output, then by the Ghostty tick that follows it, so the reread
    /// sees the parsed screen. Nothing polls on a timer; the only clock is
    /// the caller's deadline. Remote relay callers never reach this method:
    /// it is not on the relay allowlist.
    nonisolated func surfaceWaitTextChangeResponse(_ request: ControlRequest) async -> String {
        let wait: SurfaceTextChangeWaitRequest
        switch SurfaceTextChangeWaitRequest.parse(request.params) {
        case .success(let parsed):
            wait = parsed
        case .failure(let error):
            return Self.v2Encoder.error(id: request.id, code: "invalid_params", message: error.message, data: nil)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait.timeout)

        var reading = await waitTextChangeRead(wait)
        if let answer = waitTextChangeAnswer(reading, wait: wait) {
            return Self.v2Encoder.response(id: request.id, answer)
        }
        let outputSurfaceID = await waitTextChangeOutputSurfaceID(reading: reading, params: wait.readParams)

        while let outputSurfaceID, clock.now < deadline {
            // Subscribe, then reread, so output that lands between the last
            // read and the subscription still answers the wait.
            guard let output = try? await v2MainAsync({
                MobileTerminalByteTee.shared.outputUpdates(surfaceID: outputSurfaceID)
            }) else { break }
            reading = await waitTextChangeRead(wait)
            if let answer = waitTextChangeAnswer(reading, wait: wait) {
                return Self.v2Encoder.response(id: request.id, answer)
            }
            // Iterating `output` in a child task ties the subscription to the
            // group: cancelling the losing child ends the stream and releases
            // the byte tee's demand.
            let outcome = await withTaskGroup(of: WaitTextChangeOutcome.self) { group in
                group.addTask {
                    for await _ in output {
                        await Self.waitForNextGhosttyTick()
                        let next = await self.waitTextChangeRead(wait)
                        if let answer = self.waitTextChangeAnswer(next, wait: wait) {
                            return .answered(answer)
                        }
                    }
                    // The stream ended: the surface closed, or this reader
                    // fell behind a burst of output. Subscribe again.
                    return .streamEnded
                }
                group.addTask {
                    try? await clock.sleep(until: deadline)
                    return .deadline
                }
                let first = await group.next() ?? .deadline
                group.cancelAll()
                return first
            }
            if case .answered(let answer) = outcome {
                return Self.v2Encoder.response(id: request.id, answer)
            }
            if case .deadline = outcome { break }
        }

        reading = await waitTextChangeRead(wait)
        return Self.v2Encoder.response(
            id: request.id,
            waitTextChangeAnswer(reading, wait: wait, final: true) ?? reading
        )
    }

    private enum WaitTextChangeOutcome: Sendable {
        case answered(ControlCallResult)
        case streamEnded
        case deadline
    }

    /// One `surface.read_text` with the wait's read params.
    private nonisolated func waitTextChangeRead(_ wait: SurfaceTextChangeWaitRequest) async -> ControlCallResult {
        let readRequest = ControlRequest(
            id: .string("surface.wait_text_change"),
            method: "surface.read_text",
            params: wait.readParams
        )
        let encoded = await runSocketWorkerBlockingBody {
            self.socketWorkerV2Response(handling: readRequest)
        }
        return encoded.flatMap(Self.controlCallResult(fromEncodedResponse:))
            ?? .err(code: "internal_error", message: "surface.read_text returned no response", data: nil)
    }

    /// The reply for `reading`, or nil while the wait should go on.
    ///
    /// A read error ends the wait, except a terminal that is not running yet
    /// (`surface_unavailable` without a hibernation wake command): its first
    /// output is what the wait is for. `final` answers with whatever there is.
    private nonisolated func waitTextChangeAnswer(
        _ reading: ControlCallResult,
        wait: SurfaceTextChangeWaitRequest,
        final: Bool = false
    ) -> ControlCallResult? {
        switch reading {
        case .ok(.object(var payload)):
            let text: String = if case .string(let value)? = payload["text"] { value } else { "" }
            let revision = SurfaceTextChangeWaitRequest.revision(of: text)
            let changed = wait.isAnswered(byRevision: revision)
            guard changed || final else { return nil }
            payload["revision"] = .string(revision)
            payload["changed"] = .bool(changed)
            return .ok(.object(payload))
        case .ok:
            return reading
        case .err(let code, _, let data):
            if !final, code == "surface_unavailable", !Self.waitTextChangeIsHibernated(data) {
                return nil
            }
            return reading
        }
    }

    private nonisolated static func waitTextChangeIsHibernated(_ data: JSONValue?) -> Bool {
        guard case .object(let fields)? = data else { return false }
        return fields["wake_command"] != nil
    }

    /// The canonical terminal surface whose PTY output the wait listens to.
    /// A remote-tmux projection reads a different runtime surface than the
    /// panel ID it is addressed by.
    private nonisolated func waitTextChangeOutputSurfaceID(
        reading: ControlCallResult,
        params: [String: JSONValue]
    ) async -> UUID? {
        func uuid(_ value: JSONValue?) -> UUID? {
            guard case .string(let raw)? = value else { return nil }
            return UUID(uuidString: raw)
        }
        var fields: [String: JSONValue] = [:]
        if case .ok(.object(let payload)) = reading { fields = payload }
        if case .err(_, _, .object(let data)?) = reading { fields = data }
        guard let panelID = uuid(fields["surface_id"]) ?? uuid(params["surface_id"]) ?? uuid(params["terminal_id"]) else {
            return nil
        }
        let workspaceID = uuid(fields["workspace_id"]) ?? uuid(params["workspace_id"])
        let canonical = try? await v2MainAsync { () -> UUID? in
            guard let located = AppDelegate.shared?.workspaceContainingPanel(
                panelId: panelID,
                preferredWorkspaceId: workspaceID
            ) else { return nil }
            return located.workspace.controlSocketTerminalTarget(for: panelID)?.surface.id
        }
        return (canonical ?? nil) ?? panelID
    }

    /// Resumes after the next Ghostty app tick. The byte tee sees output
    /// before Ghostty parses it; the tick scheduled here runs after that
    /// output reached the main actor, so the reread sees the parsed screen.
    @MainActor
    private static func waitForNextGhosttyTick() async {
        let releaseDemand = GhosttyApp.retainTickNotifications()
        defer { releaseDemand() }
        let waiter = GhosttyNextTickWaiter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.arm(continuation)
            GhosttyApp.shared.scheduleTick()
        }
    }
}

/// Resumes one continuation on the next `.ghosttyDidTick`, then stops observing.
@MainActor
private final class GhosttyNextTickWaiter {
    private var observer: (any NSObjectProtocol)?
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    private func fire() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation?.resume()
        continuation = nil
    }
}
