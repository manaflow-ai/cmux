public import CmuxNextAgentActivity
public import Foundation

/// Share Screen with Chief's view of the cmux Computer Use helper, over its host socket
/// (``ComputerUseHelperDaemon/configuration``, which carries the host token): the helper reads the
/// screen (`display_still`, scripts/cmux-cua-display-still.patch), so Screen Recording is asked of,
/// granted to and (after a grant, "Quit & Reopen") relaunched for the helper, never this app. While
/// no helper answers, a call throws ``HelperGone`` and the sharing model checks again later; a helper
/// that stopped answering is started again by its owner. Plain Foundation types: the App declares
/// its conformance to CmuxNextDictation's `ChiefScreenCaptureHost`.
public nonisolated struct ComputerUseScreenStills: Sendable {
    /// No helper answers now.
    public struct HelperGone: Error, Equatable {}

    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    private let confirmRunning: @MainActor () -> Void

    /// - Parameter helper: The app's helper owner.
    @MainActor
    public init(helper: ComputerUseHelperDaemon) {
        configuration = { helper.configuration }
        confirmRunning = { _ = helper.confirmRunning() }
    }

    /// Whether Screen Recording is allowed for the helper (`permissions_status`).
    @concurrent
    public func screenRecordingAllowed() async throws -> Bool {
        try await send("permissions_status", deadline: .seconds(2))["screen_recording"] as? Bool ?? false
    }

    /// Raises macOS's Screen Recording request for the helper; it answers at once.
    @concurrent
    public func requestScreenRecording() async throws {
        _ = try await send("request_system_permission", name: "screen_recording", deadline: .seconds(2))
    }

    /// One host-only `display_still`.
    @concurrent
    public func displayStill(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await send("display_still", arguments, deadline: .seconds(5))
    }

    public func isHelperGone(_ error: any Error) -> Bool { error is HelperGone }

    public func refusal(_ error: any Error) -> String? {
        guard case AgentActivitySourceError.refused(let message) = error else { return nil }
        return message
    }

    @concurrent
    private func send(_ method: String, name: String? = nil, _ args: [String: Any] = [:],
                      deadline: Duration) async throws -> [String: Any] {
        guard let configuration = await configuration() else { throw HelperGone() }
        do {
            return try await CuaSocketClient(configuration: configuration).send(method, name: name, args, deadline: deadline)
        } catch let error as AgentActivitySourceError where error != .timedOut && error != .closed {
            throw error
        } catch {
            // No answer: the helper quit (macOS relaunches it after a grant) or hangs. Its owner
            // checks the process and starts a gone helper again.
            await confirmRunning()
            throw HelperGone()
        }
    }
}
