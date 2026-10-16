internal import CMUXMobileCore
public import Sentry
internal import Foundation

/// Attributes hangs from the event's captured timeline without reading UI state.
///
/// Missing, completed, or evicted phase evidence stays unknown. A later phase
/// completion must not erase the phase that was active at the event timestamp.
public struct TerminalWorkSentryContext: Sendable {
    /// Creates the stateless hang annotator.
    public init() {}

    /// Adds only fixed phase tags and bounded numeric context to a hang event.
    /// - Parameter event: The event before last-mile privacy scrubbing.
    public func apply(to event: Event) {
        guard event.exceptions?.contains(where: {
            $0.type?.hasPrefix("App Hang") == true || $0.type?.hasPrefix("Fatal App Hang") == true
                || $0.type == "WatchdogTermination" || $0.type == "MXHangDiagnostic"
                || ["AppHang", "watchdog_termination", "mx_hang_diagnostic"].contains($0.mechanism?.type ?? "")
        }) == true else { return }
        var active: [UUID: Breadcrumb] = [:]
        var sawTerminalEvidence = false
        for crumb in TerminalWorkSentryTimeline().breadcrumbs(in: event) {
            guard crumb.category == "terminal.work",
                  let timestamp = crumb.timestamp,
                  let captureTime = event.timestamp,
                  timestamp <= captureTime,
                  let data = crumb.data,
                  data["schema"] as? Int == 1,
                  let operation = (data["operation"] as? String).flatMap(UUID.init(uuidString:))
            else { continue }
            sawTerminalEvidence = true
            switch data["state"] as? String {
            case "started": active[operation] = crumb
            case "finished": active.removeValue(forKey: operation)
            default: break
            }
        }
        // A worker queue can be busy while main is blocked somewhere else.
        // Only an unfinished MAIN phase is a candidate blocking boundary.
        let current = active.values.filter { $0.data?["main_thread"] as? Bool == true }
            .max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        var tags = event.tags ?? [:]
        tags["terminal.phase"] = "unknown"
        tags["terminal.transition"] = "unknown"
        tags["terminal.evidence"] = sawTerminalEvidence ? "no_active_main_phase" : "unavailable"
        var context: [String: Any] = ["schema": 1, "unfinished_phase_count": active.count]
        if let current, let data = current.data,
           let phase = (data["phase"] as? String).flatMap(TerminalWorkDiagnostic.Phase.init(rawValue:)),
           let transition = (data["transition"] as? String).flatMap(TerminalWorkContext.Transition.init(rawValue:)) {
            tags["terminal.phase"] = phase.rawValue
            let enclosingTransition = active.values.filter { $0.data?["main_thread"] as? Bool == true }
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                .compactMap { ($0.data?["transition"] as? String).flatMap(TerminalWorkContext.Transition.init(rawValue:)) }
                .first { $0 != .unknown }
            tags["terminal.transition"] = (transition == .unknown ? enclosingTransition ?? .unknown : transition).rawValue
            tags["terminal.evidence"] = "unfinished_at_capture"
            for key in ["workspace_count", "surface_count"] {
                if let count = data[key] as? Int { context[key] = min(max(0, count), Int(UInt16.max)) }
            }
            if let population = (data["population"] as? String).flatMap(TerminalWorkContext.Population.init(rawValue:)) {
                context["population"] = population.rawValue
            }
            if let captured = event.timestamp, let started = current.timestamp {
                context["elapsed_ms_at_capture"] = min(max(0, captured.timeIntervalSince(started) * 1_000), Double(UInt32.max))
            }
        }
        // Preserve worker evidence separately; it is not asserted to block main.
        context["unfinished_worker_phases"] = Array(Set(active.values.compactMap { crumb -> String? in
            guard crumb.data?["main_thread"] as? Bool == false,
                  let raw = crumb.data?["phase"] as? String,
                  let phase = TerminalWorkDiagnostic.Phase(rawValue: raw) else { return nil }
            return phase.rawValue
        })).sorted()
        event.tags = tags
        var contexts = event.context ?? [:]
        contexts["cmux.terminal_work"] = context
        event.context = contexts
    }
}
