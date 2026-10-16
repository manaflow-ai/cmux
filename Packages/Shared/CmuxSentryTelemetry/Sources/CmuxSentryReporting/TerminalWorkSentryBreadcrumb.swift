public import CMUXMobileCore
public import Foundation
public import Sentry

/// Converts typed phase records into a bounded, content-free hang timeline.
public struct TerminalWorkSentryBreadcrumb: Sendable {
    /// Creates the stateless converter.
    public init() {}

    /// Formats a phase record off the instrumented executor.
    /// - Parameters:
    ///   - event: A terminal begin/end record.
    ///   - role: The app platform role.
    ///   - wallTime: Wall-clock anchor at delivery, injectable for tests.
    ///   - uptime: Matching monotonic anchor, injectable for tests.
    /// - Returns: A breadcrumb, or nil for a non-terminal record.
    public func make(
        _ event: DiagnosticEvent,
        role: String,
        wallTime: Date = .now,
        uptime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Breadcrumb? {
        guard event.code == .terminalWorkStarted || event.code == .terminalWorkFinished,
              let work = event.terminalWork else { return nil }
        let crumb = Breadcrumb(level: .info, category: "terminal.work")
        // Use the producer time, not the later drain time. A begin queued
        // before a hang must still precede the hang's capture timestamp.
        let delta = event.tNanos <= uptime ? -Double(uptime - event.tNanos) : Double(event.tNanos - uptime)
        crumb.timestamp = wallTime.addingTimeInterval(delta / 1_000_000_000)
        crumb.message = work.phase.rawValue
        var data: [String: Any] = [
            "schema": 1,
            "operation": work.operationID.uuidString,
            "phase": work.phase.rawValue,
            "transition": work.context.transition.rawValue,
            "population": work.context.population.rawValue,
            "main_thread": work.onMainThread,
            "role": role,
            "state": event.code == .terminalWorkStarted ? "started" : "finished"
        ]
        if let count = work.context.workspaceCount { data["workspace_count"] = count }
        if let count = work.context.surfaceCount { data["surface_count"] = count }
        if let ms = event.ms { data["duration_ms"] = ms }
        crumb.replaceData(data)
        return crumb
    }
}
