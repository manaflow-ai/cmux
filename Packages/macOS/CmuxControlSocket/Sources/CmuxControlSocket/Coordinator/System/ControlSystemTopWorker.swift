internal import Foundation

/// The worker-lane RPC handler for the v2 `system.top` / `system.memory`
/// resource-monitor commands, lifted byte-faithfully from the former
/// `TerminalController` `v2SystemTop` / `v2SystemMemory` dispatch arms.
///
/// Owns the command dispatch only. The entire body of each command (the
/// `v2SystemTopBasePayload` live-graph walk + param validation, the
/// `CmuxTopProcessSnapshot` sampling, the `[String: Any]` annotation pipeline,
/// and the final payload assembly) is built app-side and carried through the
/// ``ControlSystemTopReading`` seam verbatim, exactly like the read-only browser
/// getters: the work reaches `AppDelegate` and an app-target process snapshot,
/// which this control package must not import.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane. The legacy `v2SystemTop` / `v2SystemMemory` bodies were
/// `nonisolated` and sampled the process snapshot on the worker thread, hopping
/// to the main actor only inside the `v2MainSync` base-payload block.
/// ``handle(_:)`` is synchronous and runs on the calling worker thread, exactly
/// as the legacy bodies did; the seam's main-actor hop stays inside the
/// conformer. It does no socket I/O and never imports the app target.
public struct ControlSystemTopWorker: Sendable {
    /// The live system-top seam. Injected at construction.
    private let reading: any ControlSystemTopReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The system-top seam to read/drive.
    public init(reading: any ControlSystemTopReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is `system.top` or `system.memory`,
    /// returning the result; returns `nil` for any other method so the caller
    /// can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "system.top":
            return reading.resolveTop(params: request.params)
        case "system.memory":
            return reading.resolveMemory(params: request.params)
        default:
            return nil
        }
    }
}
