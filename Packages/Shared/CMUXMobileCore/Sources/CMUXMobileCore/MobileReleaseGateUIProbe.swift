#if DEBUG
import Foundation

/// One cold-launch UI measurement. The recorder survives SwiftUI reconstruction
/// and later soak output; it never substitutes model readiness for presentation.
@MainActor
public final class MobileReleaseGateUIProbe {
    /// Lifecycle events accepted by the release-gate recorder.
    public enum EventKind: Sendable {
        /// The app root became visible.
        case appRootVisible, workspaceListVisible, workspaceSelectionTapped
        /// The workspace row was selected.
        case workspaceDetailVisible, terminalFramePresented
    }
    /// Errors raised when the debug-only UI path cannot produce evidence.
    public enum Failure: String, Error {
        /// The probe was not installed or the requested surface was unavailable.
        case unavailable = "ui_probe_unavailable"
        /// The requested UI transition did not complete before its deadline.
        case timedOut = "ui_readiness_timed_out"
    }
    private enum Phase { case disabled, awaitingSelection, opening, presented, closing, complete }
    private struct Row {
        let appeared: UInt64
        let select: @MainActor () -> Bool
    }
    private var phase = Phase.disabled
    private var started: UInt64?
    private var rows: [String: Row] = [:]
    private var targetWorkspace: String?
    private var targetSurface: String?
    private var tap: UInt64?
    private var detail: UInt64?
    private var measured: [String: Double] = [:]
    private var changes: AsyncStream<Void>.Continuation?
    /// Callback that reveals a target row when it is offscreen or collapsed.
    public var revealWorkspace: (@MainActor (String) -> Void)? {
        didSet {
            if awaitsVisibleRows, let targetWorkspace { revealWorkspace?(targetWorkspace) }
        }
    }
    /// Callback that captures the compositor-backed terminal evidence frame.
    public var captureTerminalEvidence: (@MainActor () async throws -> Void)?
    /// Callback that returns the shell to the workspace list after capture.
    public var closeWorkspace: (@MainActor () -> Void)?

    /// Whether the recorder is waiting for a real visible workspace row.
    public var awaitsVisibleRows: Bool { phase == .awaitingSelection }

    private let timeoutClock: any Clock<Duration>

    /// Creates a recorder for one cold app launch.
    ///
    /// - Parameters:
    ///   - enabled: Whether recording is active.
    ///   - launchUptimeNanoseconds: The simulator launch request timestamp.
    ///   - timeoutClock: Clock used for bounded UI waits.
    public init(enabled: Bool = true, launchUptimeNanoseconds: UInt64? = nil,
                timeoutClock: any Clock<Duration> = ContinuousClock()) {
        self.timeoutClock = timeoutClock
        if enabled {
            let now = DispatchTime.now().uptimeNanoseconds
            let origin = launchUptimeNanoseconds ?? now
            guard origin > 0, origin <= now else { return }
            started = origin
            phase = .awaitingSelection
        }
    }

    /// Registers a row that is actually attached and selectable in UIKit.
    /// Selection revalidates the cell before invoking the same delegate as a
    /// user's tap.
    public func registerVisibleWorkspace(_ id: String, select: @escaping @MainActor () -> Bool) {
        guard awaitsVisibleRows else { return }
        if rows.count >= 32, rows[id] == nil {
            guard id == targetWorkspace else { return }
            rows.removeAll()
        }
        rows[id] = Row(appeared: rows[id]?.appeared ?? DispatchTime.now().uptimeNanoseconds, select: select)
        selectIfReady()
    }

    private func selectIfReady() {
        guard phase == .awaitingSelection, let id = targetWorkspace, let row = rows[id], let started else { return }
        phase = .opening
        measured["app_launch_request_to_workspace_rows_visible"] = seconds(row.appeared - started)
        if row.select() {
            rows.removeAll()
        } else {
            measured.removeAll()
            phase = .awaitingSelection
            rows.removeValue(forKey: id)
        }
    }

    /// Records a lifecycle event from the rendered shell.
    public func record(_ kind: EventKind) {
        let now = DispatchTime.now().uptimeNanoseconds
        switch kind {
        case .workspaceSelectionTapped where phase == .opening:
            if tap == nil { tap = now }
        case .workspaceDetailVisible where phase == .opening:
            if detail == nil { detail = now }
        default:
            break // Empty-list onAppear, repeated frames and unrelated views prove nothing.
        }
    }

    /// Records teardown of the selected terminal surface.
    public func terminalDidUnmount(surfaceID: String) {
        guard phase == .closing, surfaceID == targetSurface else { return }
        phase = .complete
        changes?.yield(())
    }

    /// Records a nonblank frame from the selected terminal surface.
    @discardableResult
    public func recordTerminalFrame(surfaceID: String, containsText: @autoclosure () -> Bool) -> Bool {
        guard phase == .opening, surfaceID == targetSurface, let tap, containsText() else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        measured["workspace_tap_to_terminal_text_visible"] = seconds(now - tap)
        if let detail, detail >= tap, detail <= now {
            measured["workspace_tap_to_detail_visible"] = seconds(detail - tap)
            measured["workspace_detail_to_terminal_text_visible"] = seconds(now - detail)
        }
        phase = .presented
        changes?.yield(())
        return true
    }

    /// Drives the same selection path as a user tap and waits for presentation.
    public func exercise(workspaceID: String, surfaceID: String,
                                timeout: Duration = .seconds(60)) async throws {
        guard phase == .awaitingSelection, started != nil else { throw Failure.unavailable }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        defer {
            continuation.finish()
            changes = nil
            rows.removeAll()
            closeWorkspace = nil
            revealWorkspace = nil
            captureTerminalEvidence = nil
        }
        targetWorkspace = workspaceID
        targetSurface = surfaceID
        revealWorkspace?(workspaceID)
        selectIfReady()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable [stream] in
                try await self.waitForPresentation(stream)
            }
            group.addTask { [timeoutClock] in
                try await timeoutClock.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitForPresentation(_ stream: AsyncStream<Void>) async throws {
        for await _ in stream {
            if phase == .presented {
                try await captureTerminalEvidence?()
                try Task.checkCancellation()
                guard let closeWorkspace else { throw Failure.unavailable }
                phase = .closing
                closeWorkspace()
            }
            if phase == .complete { return }
        }
        throw CancellationError()
    }

    /// Returns the real monotonic durations captured by this launch.
    public func latencies() -> [String: Double] { measured }
    private func seconds(_ value: UInt64) -> Double { Double(value) / 1_000_000_000 }
}
#endif
