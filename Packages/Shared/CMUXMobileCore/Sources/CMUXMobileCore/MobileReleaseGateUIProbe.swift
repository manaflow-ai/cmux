#if DEBUG
import Foundation

/// One cold-launch UI measurement. The recorder survives SwiftUI reconstruction
/// and later soak output; it never substitutes model readiness for presentation.
@MainActor
public enum MobileReleaseGateUIProbe {
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
    private static var phase = Phase.disabled
    private static var started: UInt64?
    private static var rows: [String: Row] = [:]
    private static var targetWorkspace: String?
    private static var targetSurface: String?
    private static var tap: UInt64?
    private static var detail: UInt64?
    private static var measured: [String: Double] = [:]
    private static var changes: AsyncStream<Void>.Continuation?
    public static var closeWorkspace: (@MainActor () -> Void)?

    public static var awaitsVisibleRows: Bool { phase == .awaitingSelection }

    public static func beginLaunch(enabled: Bool) {
        guard enabled, started == nil else { return }
        reset()
    }

    /// Explicit reset for isolated unit tests. Production initializes once in App.init.
    public static func reset() {
        changes?.finish()
        changes = nil
        started = DispatchTime.now().uptimeNanoseconds
        phase = .awaitingSelection
        rows.removeAll()
        measured.removeAll()
        targetWorkspace = nil
        targetSurface = nil
        tap = nil
        detail = nil
        closeWorkspace = nil
    }

    /// Called only for an attached, visible, connected workspace row. Selection
    /// revalidates the cell before invoking the same delegate as a user's tap.
    public static func registerVisibleWorkspace(_ id: String, select: @escaping @MainActor () -> Bool) {
        guard awaitsVisibleRows else { return }
        if rows.count >= 32, rows[id] == nil { return }
        rows[id] = Row(appeared: rows[id]?.appeared ?? DispatchTime.now().uptimeNanoseconds, select: select)
        selectIfReady()
    }

    private static func selectIfReady() {
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

    public static func record(_ kind: EventKind) {
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

    public static func terminalDidUnmount(surfaceID: String) {
        guard phase == .closing, surfaceID == targetSurface else { return }
        phase = .complete
        changes?.yield(())
    }

    @discardableResult
    public static func recordTerminalFrame(surfaceID: String, containsText: Bool) -> Bool {
        guard phase == .opening, surfaceID == targetSurface, containsText, let tap else { return false }
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

    public static func exercise(workspaceID: String, surfaceID: String,
                                timeout: Duration = .seconds(60)) async throws {
        guard phase == .awaitingSelection, started != nil else { throw Failure.unavailable }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        defer {
            continuation.finish()
            changes = nil
            rows.removeAll()
            closeWorkspace = nil
        }
        targetWorkspace = workspaceID
        targetSurface = surfaceID
        selectIfReady()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable [stream] in
                try await waitForPresentation(stream)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func waitForPresentation(_ stream: AsyncStream<Void>) async throws {
        for await _ in stream {
            if phase == .presented {
                guard let closeWorkspace else { throw Failure.unavailable }
                phase = .closing
                closeWorkspace()
            }
            if phase == .complete { return }
        }
        throw CancellationError()
    }

    public static func latencies() -> [String: Double] { measured }
    private static func seconds(_ value: UInt64) -> Double { Double(value) / 1_000_000_000 }
}
#endif
