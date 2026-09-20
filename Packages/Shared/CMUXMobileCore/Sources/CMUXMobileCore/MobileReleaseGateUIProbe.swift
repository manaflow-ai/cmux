#if DEBUG
import Foundation

/// One cold-launch UI measurement. The recorder survives SwiftUI reconstruction
/// and later soak output; it never substitutes model readiness for presentation.
@MainActor
public final class MobileReleaseGateUIProbe {
    public enum EventKind: Sendable {
        case appRootVisible, workspaceListVisible, workspaceSelectionTapped
        case workspaceDetailVisible, terminalFramePresented
    }
    public enum Failure: String, Error {
        case unavailable = "ui_probe_unavailable"
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
    public var revealWorkspace: (@MainActor (String) -> Void)? {
        didSet {
            if awaitsVisibleRows, let targetWorkspace { revealWorkspace?(targetWorkspace) }
        }
    }
    public var captureTerminalEvidence: (@MainActor () async throws -> Void)?
    public var closeWorkspace: (@MainActor () -> Void)?

    public var awaitsVisibleRows: Bool { phase == .awaitingSelection }

    private let timeoutClock: any Clock<Duration>

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

    /// Called only for an attached, visible, connected workspace row. Selection
    /// revalidates the cell before invoking the same delegate as a user's tap.
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
        measured["app_launch_to_workspace_rows_visible"] = seconds(row.appeared - started)
        if row.select() {
            rows.removeAll()
        } else {
            measured.removeAll()
            phase = .awaitingSelection
            rows.removeValue(forKey: id)
        }
    }

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

    public func terminalDidUnmount(surfaceID: String) {
        guard phase == .closing, surfaceID == targetSurface else { return }
        phase = .complete
        changes?.yield(())
    }

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

    public func latencies() -> [String: Double] { measured }
    private func seconds(_ value: UInt64) -> Double { Double(value) / 1_000_000_000 }
}
#endif
