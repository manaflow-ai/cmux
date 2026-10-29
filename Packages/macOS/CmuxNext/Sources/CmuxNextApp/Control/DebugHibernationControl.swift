import CmuxNextCompat
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextSettings

/// The memory methods of the control socket:
///
/// - `debug.memory` (every build, read-only): ``DebugMemoryControl``.
/// - `debug.discards` (every build, read-only): cmux's chrome://discards
///   (`chrome/browser/ui/webui/discards/discards_ui.cc`) over the rows the discard planner's owners
///   report (``ContentDiscardReport``): the nine content kinds and one row per content.
///   Its socket policy is `debug.memory`'s (``DebugMemoryControl``): the main-actor
///   body only copies the report, a value; `kind` is parsed and the answer filtered, redacted
///   (``MemoryDiagnosticsReport/opaqueToken(_:)`` on every content key) and encoded off the main actor.
/// - `debug.hibernation.pressure` (DEBUG builds): sets the memory coordinator's pressure override, which
///   the coordinator hands to browser tab hibernation (a registered `MemoryLevelConsumer`), so the fleet
///   benches (scripts/measure/tab-hibernation.sh) measure pressure without `sudo memory_pressure`.
///   `level` is normal, warning or critical and holds for both, whatever the kernel reports, until
///   `none` clears it and hands both the kernel's level again. The reply keeps `pressure`
///   (hibernation's level) and adds the coordinator's `level` and the `override`. `debug.memory`'s
///   pressure history and histograms record each override.
@MainActor
enum DebugHibernationControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        let memory = DebugMemoryControl(services: services, budget: .forThisMac(gpuResidentAvailable: services.cache.gpuResidency != nil))
        let discards = discardsMethod { [weak services] in services?.cache.hibernation?.discards ?? ContentDiscardReport() }
        #if DEBUG || CMUX_BENCH_HOOKS
        return [memory.method, discards, pressureMethod(services, history: memory.history, histograms: memory.histograms)]
        #else
        return [memory.method, discards]
        #endif
    }

    /// `debug.discards` over `read`. Before hibernation starts (or once the app's services are gone)
    /// `read` gives an empty report: the nine kinds, none tracked, and no rows.
    ///
    /// - Parameters:
    ///   - read: The owners' report now, read on the main actor.
    ///   - now: The time `hidden_for` is measured to.
    static func discardsMethod(
        read: @escaping @MainActor @Sendable () -> ContentDiscardReport,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> ControlMethod {
        ControlMethod.mainActor("debug.discards") { call in
            let report = read()
            let params = call.params
            return .followUp { try discardsAnswer(report, params: params, now: now()) }
        }.servingRelease()
    }

    /// The `debug.discards` answer for `params` (`{"kind": "<kind>"}` keeps one kind), every key redacted.
    nonisolated static func discardsAnswer(_ report: ContentDiscardReport, params: [String: JSONValue],
                                           now: ContinuousClock.Instant) throws -> JSONValue {
        let only = try discardsKind(params)
        let kinds = report.kinds.filter { only == nil || $0.kind == only }
        let rows = report.rows(now: now).filter { only == nil || $0.kind == only }.map { row in
            var redacted = row
            redacted.key = MemoryDiagnosticsReport.opaqueToken(row.key)
            return redacted
        }
        return ["kinds": .array(kinds.map(\.json)), "contents": .array(rows.map(\.json))]
    }

    /// The `kind` parameter of `debug.discards`: nil when absent, else one of the nine kinds.
    nonisolated static func discardsKind(_ params: [String: JSONValue]) throws -> ContentKind? {
        guard let raw = params["kind"], !raw.isNull else { return nil }
        guard let name = raw.stringValue, let kind = ContentKind(rawValue: name) else {
            throw ControlError.invalidParams("kind must be one of " + ContentKind.allCases.map(\.rawValue).joined(separator: ", "),
                                             data: ["param": "kind"])
        }
        return kind
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private static func pressureMethod(_ services: AppServices, history: MemoryPressureHistory,
                                       histograms: MemoryHistograms) -> ControlMethod {
        .mainActor("debug.hibernation.pressure") { [weak services] call in
            let raw = call.params["level"]?.stringValue
            let level = raw.flatMap(MemoryPressureLevel.init(rawValue:))
            guard level != nil || raw == "none" else {
                return .value(.object(["error": .string("level must be normal, warning, critical or none")]))
            }
            guard let services else { return .value(.null) }
            let coordinator = services.memoryCoordinator
            let reply = applyOverride(level, coordinator: coordinator, hibernation: services.cache.hibernation)
            history.overrideDidChange(coordinator.pressureOverride)
            histograms.overrideDidChange(coordinator.pressureOverride)
            return .value(reply)
        }
    }

    /// Sets `coordinator`'s pressure override (nil clears it). The coordinator hands the new level to
    /// every registered `MemoryLevelConsumer` in the same turn, `hibernation` included once started.
    ///
    /// - Parameters:
    ///   - level: The level to hold, or nil for the kernel's level.
    ///   - coordinator: The app's memory coordinator.
    ///   - hibernation: The app's browser hibernation, nil before it starts.
    /// - Returns: The reply: the coordinator's `level`, the `override` and hibernation's `pressure`.
    static func applyOverride(_ level: MemoryPressureLevel?, coordinator: MemoryCoordinator,
                              hibernation: BrowserHibernation?) -> JSONValue {
        coordinator.pressureOverride = level
        var reply: [String: JSONValue] = [
            "level": .string(coordinator.level.rawValue),
            "override": level.map { .string($0.rawValue) } ?? .null,
        ]
        if let hibernation { reply["pressure"] = .string(hibernation.pressure.rawValue) }
        return .object(reply)
    }
    #endif
}
