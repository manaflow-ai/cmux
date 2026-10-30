import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextEnergy
import CmuxNextSettings
import CmuxNextWakeups
import Darwin

/// `debug.wakeups`: who wakes this app and how much CPU the app, its
/// Chromium helpers and its cmux-tui daemon (with terminal hosts) use
/// (plans/cmux-next/idle-wakeups.md).
///
/// - `ledger`: every sanctioned primitive's wakeups per owner and reason,
///   with a rate over the last 10 complete seconds.
/// - `frame_schedulers`: each window's display link, its active clients and the links it made, and the app's
///   budgeted scheduler (``MainWorkScheduler``: the control queue, the daemon store drain).
/// - `vsync` (feature `vsyncHub`, else null): the ``VSyncHub``'s live links (displays with an armed subscriber),
///   paused links, threads and its main fan-out's hop (`main_hop_p99_ms`; threading-model.md's VSyncHub row).
/// - `processes`: cumulative CPU time and wakeups per process (diff two
///   calls for rates; `scripts/cmux-next/bench-idle.py` does), sampled off
///   the main actor.
/// - `main_run_loop` (with `run_loop: true`): the main run loop's description (`CFCopyDescription`):
///   every mode's timers with their interval and callout, sources and observers. An idle bench reads
///   the repeating timers from it to name what wakes the main thread outside the ledger.
enum DebugWakeups {
    /// `helperParent`: whose children the Chromium helpers are (``ChromiumHelperParent/pid``).
    static func report(_ params: [String: JSONValue], budgeted: FrameScheduler, helperParent: pid_t?) async -> JSONValue {
        var object = mainActorPart(params, budgeted: budgeted)
        object["processes"] = .array(AppProcesses.sample(helperParent: helperParent).map(\.json))
        return .object(object)
    }

    @MainActor
    private static func mainActorPart(_ params: [String: JSONValue], budgeted: FrameScheduler) -> [String: JSONValue] {
        if params["reset"]?.boolValue == true { WakeupLedger.shared.reset() }
        let ledger = WakeupLedger.shared.snapshot()
        let all = FrameScheduler.all + [budgeted]
        let schedulers = all.map { scheduler -> JSONValue in
            [
                "name": .string(scheduler.name),
                "running": .bool(scheduler.isRunning),
                "has_link": .bool(scheduler.hasLink),
                "frames": JSONValue(Int(truncatingIfNeeded: scheduler.frames)),
                "links_made": JSONValue(Int(truncatingIfNeeded: scheduler.linksMade)),
                "active_clients": .array(scheduler.activeClients.map { .string($0) }),
            ]
        }
        var report: [String: JSONValue] = [
            "uptime_s": .number(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9),
            "total_per_second": .number(ledger.reduce(0) { $0 + $1.perSecond }),
            "ledger": .array(ledger.map { entry in
                [
                    "owner": .string(entry.owner), "reason": .string(entry.reason),
                    "count": JSONValue(Int(truncatingIfNeeded: entry.count)),
                    "per_second": .number(entry.perSecond),
                    "seconds_since_last": .number(entry.secondsSinceLast),
                ]
            }),
            "frame_schedulers": .array(schedulers),
            "display_links": JSONValue(budgeted.displayClock.liveLinks),
            "vsync": budgeted.displayClock.hub.map { hub in JSONValue.object(hub.debugCounts.mapValues { JSONValue.number($0) }) } ?? JSONValue.null,
            "active_frame_clients": .array(all.flatMap(\.activeClients).map { .string($0) }),
        ]
        if params["run_loop"]?.boolValue == true {
            report["main_run_loop"] = .string(CFCopyDescription(CFRunLoopGetMain()) as String)
        }
        return report
    }
}

/// This app, its Chromium helpers, and the bundled cmux-tui (daemon and
/// terminal hosts). The helpers are the children of `helperParent`
/// (``ChromiumHelperParent/pid``): the app in process, the Chromium Host in
/// host mode, none while no host is attached.
nonisolated enum AppProcesses {
    struct Sample {
        var kind: String
        var usage: ProcessUsage
        /// A tab renderer's client id (``tabRendererClients()``); nil for every other process.
        var rendererClientID: Int32?

        var json: JSONValue {
            [
                "kind": .string(kind), "pid": JSONValue(Int(usage.pid)), "parent": JSONValue(Int(usage.parent)),
                "name": .string(usage.name),
                "cpu_ms": .number(Double(usage.cpuNanos) / 1e6),
                "wakeups": JSONValue(Int(truncatingIfNeeded: usage.wakeups)),
                "footprint_mb": .number(Double(usage.physFootprint) / 1_048_576),
                "uptime_ns": JSONValue(Int(truncatingIfNeeded: usage.uptimeNanos)),
            ]
        }
    }

    /// Chromium helper kinds, from the helper app's name.
    static func helperKind(_ path: String) -> String? {
        guard path.contains(" Helper") else { return nil }
        for kind in ["Renderer", "GPU", "Plugin", "Alerts"] where path.contains("(\(kind))") {
            return "cef-\(kind.lowercased())"
        }
        return "cef-helper"
    }

    /// Chromium helpers for the busy watchdog, labeled with their kind; a tab renderer carries its client
    /// id. Chromium assigns renderers per site, so the tabs a busy renderer serves come from the
    /// watchdog's tab source (``TabContentCache/tabRenderers``).
    static func chromiumHelpers(helperParent: pid_t?) -> [BusyWatchdog.Helper] {
        guard let helperParent else { return [] }
        let renderers = tabRendererClients(helperParent: helperParent)
        return ProcessUsage.children(of: helperParent).compactMap { pid in
            guard let path = ProcessUsage.path(of: pid), let kind = helperKind(path) else { return nil }
            return BusyWatchdog.Helper(pid: pid, label: kind, rendererClientID: renderers[pid])
        }
    }

    /// The tab renderers of `helperParent` by pid, with their `--renderer-client-id`, from ``ChromiumHelperProcess``
    /// (argv cached per pid; extension renderers are not tab renderers).
    static func tabRendererClients(helperParent: pid_t?) -> [pid_t: Int32] {
        var clients: [pid_t: Int32] = [:]
        for helper in ChromiumHelperProcess.list(parent: helperParent) {
            if case .renderer(let clientID) = helper.kind { clients[helper.pid] = clientID }
        }
        return clients
    }

    /// Every Chromium tab with what it reports about its renderers, read now: the pids
    /// are matched to processes off the main actor.
    @MainActor
    static func tabRenderers(_ services: AppServices) -> [ProcessUsage.TabRenderers] {
        services.cache.browsers.sorted { $0.key < $1.key }.compactMap { id, entry in
            (entry.tab as? CEFTab)?.renderers(tab: id)
        }
    }

    static func sample(helperParent: pid_t?) -> [Sample] {
        let me = getpid()
        var out: [Sample] = []
        if let usage = ProcessUsage.sample(me) { out.append(Sample(kind: "app", usage: usage)) }
        let renderers = tabRendererClients(helperParent: helperParent)
        // The app's children, then the Chromium Host's in host mode (its helpers are not the app's).
        let hostChildren = helperParent.flatMap { $0 == me ? nil : ProcessUsage.children(of: $0) } ?? []
        for child in ProcessUsage.children(of: me) + hostChildren {
            guard let usage = ProcessUsage.sample(child), let kind = helperKind(usage.path) else { continue }
            out.append(Sample(kind: kind, usage: usage, rendererClientID: renderers[child]))
        }
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin").path + "/"
        let tui = ProcessUsage.processes(pathPrefix: bin).compactMap(ProcessUsage.sample)
        for usage in tui {
            // Terminal hosts run the same binary with `__terminal-host`.
            let isHost = ProcessUsage.arguments(of: usage.pid).contains { $0.hasPrefix("__terminal-host") }
            out.append(Sample(kind: isHost ? "terminal-host" : "daemon", usage: usage))
        }
        return out
    }
}

extension EnergyReport {
    /// `debug.energy` over the energy services AppServices builds once: the monitor's
    /// inputs, ``EnergyServices``' driver (its resolver state) and idle histogram, the
    /// scheduler's policy and wake queue; the app's ledger (where the main wake queue counts its wakes);
    /// and one sample of the processes ``AppProcesses`` lists.
    init(services: AppServices) {
        self.init(state: { [weak services] in services.map(Self.state) }, ledger: .shared, processes: { [parent = services.cache.chromium.source.helperParent] in
            AppProcesses.sample(helperParent: parent.pid).map { ProcessSample(kind: $0.kind, usage: $0.usage, rendererClientID: $0.rendererClientID) }
        })
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.energy.simulate` over the app's one ``EnergyMonitor``.
    static func simulateMethod(services: AppServices) -> ControlMethod {
        EnergyReport(services: services).simulateMethod { [weak services] in services?.energyMonitor.simulate($0) }
    }
    #endif

    /// `energy.status` over the same services, in every build: the policy and its inputs only.
    static func statusMethod(services: AppServices) -> ControlMethod {
        statusMethod { [weak services] in services.map { (policy: $0.mainWork.energy.policy, inputs: inputs($0)) } }
    }

    private static func inputs(_ services: AppServices) -> Inputs {
        let inputs = services.energyMonitor.inputs
        let driver = services.energy.driver
        return Inputs(featureEnabled: driver.isEnabled, lowPowerMode: inputs.lowPowerMode, onBattery: inputs.onBattery,
                      hasBattery: inputs.hasBattery, batteryPercent: inputs.batteryPercent, thermal: inputs.thermal,
                      setting: services.settings?.snapshot.energySaver ?? EnergySaverSetting.defaultValue,
                      sessionOverride: driver.isOffForSession, simulated: services.energyMonitor.isSimulated)
    }

    private static func state(_ services: AppServices) -> State {
        let wakeUps = services.mainWork.wakeUps
        return State(
            policy: services.mainWork.energy.policy,
            inputs: inputs(services),
            wakeQueue: WakeQueue(entries: wakeUps.count, coalescedFires: wakeUps.coalescedFires),
            // No early-pass count yet.
            cef: CEF(saver: CEF.Saver(applied: services.cache.chromium.built?.energySaverApplied), earlyPasses: nil),
            idle: services.energy.idle.stats,
            tabs: AppProcesses.tabRenderers(services)
        )
    }
}
