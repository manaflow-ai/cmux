/// One field histogram in the cmux catalog: its name, unit, bucket layout, owner and expiry
/// (plans/cmux-next/chrome-parity/p09-observability.md section 3D).
///
/// Chrome's model (tools/metrics/histograms/*.xml, base/metrics/histogram_macros.h): every histogram
/// has owners, a unit, a summary and `expires_after`, a static bucket layout and lock-free recording.
/// Here the cases are the catalog, as `SignpostName` is for trace points: a hang report sends only
/// these names, and `allCases` is the list readers enumerate. An expired id records nothing (task 052).
/// The catalog was frozen for the p09-observability program (task 000): a task that records a
/// histogram uses these cases and edits neither this file nor HistogramID+Dimensions.swift (a dimension
/// value is part of a histogram's name); a missing one is a follow-up to task 000.
///
/// A case with a dimension is one histogram per dimension value (`key.frame.view`,
/// `key.frame.terminal`); the dimensions are in HistogramID+Dimensions.swift.
///
/// ```swift
/// Metrics().record(.keyFrame(.terminal), elapsedMicroseconds)
/// ```
public enum HistogramID: Sendable, Hashable {
    // MARK: typing and input (PL-typing)

    /// A key-down to the end of the commit of its turn, per target, in us (task 054).
    case keyFrame(KeyTarget)
    /// A sampled key (1 in 16) to the contents of the frame that shows its echo, per route, in us (054, 116).
    case keyEchoFrame(EchoRoute)
    /// Another input event to the next content-changing commit, per kind, in us (Chrome's EventLatency; 111).
    case inputFrame(InputKind)

    // MARK: frames and motion (PL-motion-core)

    /// A live-resize tick to the commit that shows it, in us (task 111).
    case resizeFrame
    /// Dropped frames of a frame sequence, in percent of the expected frames (task 057, 113, 127).
    case smoothnessDroppedPercent(FrameSequence)
    /// The time between committed frames while a sequence runs, in us (task 057).
    case frameInterval

    // MARK: main thread (Performance Lead)

    /// One main run-loop turn's busy time, in us (task 055).
    case mainTurn
    /// A main-thread job's wait from its post to its run, in us (task 112).
    case mainQueueDelay
    /// Congested time per 30 s interval, by measure and startup stage, in ms (Chrome's responsiveness
    /// calculator; task 112).
    case mainCongestion(CongestionKind, StartupStage)

    // MARK: hangs (PL-telemetry)

    /// Main-thread stalls of 250 ms or more per active hour (task 055).
    case hangOver250PerHour
    /// Hangs of a watched lane per active hour (task 067).
    case hangThreadHung(HangLane)

    // MARK: actions (Performance Lead)

    /// An action's start to the end of its commit, per entrypoint, in us (task 056).
    case actionCommit(Entrypoint)
    /// Cmd-T, Cmd-N or Cmd-W to the commit that shows its result, in us (task 056).
    case actionCommand(Command)
    /// Frames missed in the 3 frames after Cmd-T, Cmd-N or Cmd-W (task 056, 057).
    case actionMissedFrames(Command)

    // MARK: launch (Performance Lead)

    /// The process start to the first window's first frame, per launch temperature, in ms (task 058).
    case launchFirstFrame(LaunchTemperature)
    /// The page-ins at the first main run-loop turn, the launch temperature's source (task 034).
    case launchPageins

    // MARK: wakeups and resources (Performance Lead, PL-telemetry)

    /// Wakeups per idle minute (task 059).
    case idleWakeups(WakeupSource)
    /// The physical footprint of a process kind, in KiB (task 121).
    case memory(ProcessKind)
    /// The physical footprint of every cmux process together, in KiB (task 121).
    case memoryTotal
    /// The memory a hidden workspace holds, in KiB, sampled only when its renderers are clear (task 061).
    case memoryHiddenWorkspace
    /// A process kind's CPU use between two samples, in percent of one core (task 121).
    case cpu(ProcessKind)
    /// Disk writes per idle minute, in KiB (task 121).
    case diskIdleWrite

    // MARK: Chromium and web pages (PL-cef-tab, PL-telemetry)

    /// One Chromium message pump pass, in us (task 060).
    case cefPump
    /// An abnormal Chromium helper exit: process type times 16 plus the reason (task 060, 083).
    case cefHelperExit
    /// A Chromium page's unresponsive time, from shown to ended, in ms (task 108).
    case rendererUnresponsive
    /// A slow interaction in a cmux web page, in ms (Interaction to Next Paint; task 114).
    case webviewINP(Page)
    /// A long animation frame in a cmux web page, in ms (task 114).
    case webviewLoAF(Page)
    /// Script errors and unhandled rejections in a cmux web page per page load (task 114).
    case webviewJSErrors(Page)
    /// A Chromium histogram read from `base::StatisticsRecorder`, in Chromium's own buckets (task 107).
    case chromium(Chromium)

    // MARK: daemon and automation (PL-daemon, Performance Lead)

    /// A daemon request's arrival to its reply sent, per class, in us (task 062, 131).
    case daemonRequest(MethodClass)
    /// A daemon request's wait from its arrival to its dispatch, in us (task 014, 112).
    case daemonDispatchQueue
    /// A control-socket request (CLI, MCP, agent) from accept to reply, per class, in us (task 115).
    case automationRequest(MethodClass)
    /// A control-socket request's wait for the main thread, in us (task 115).
    case automationMainQueue
    /// How long a person's input waited behind automation work, in us (task 115).
    case automationBlockedPerson
    /// A tokio runtime's busy time per report interval, in ms (task 118).
    case runtimeBusy
    /// The remote desktop view's input to the frame that shows it, in us (task 127).
    case remoteInputToPresent

    // MARK: stability (PL-telemetry)

    /// One app launch (the denominator of the stability counts; task 109).
    case stabilityLaunch
    /// Seconds the app was active per launch (task 109).
    case stabilityActiveSeconds
    /// How the last run ended when it did not quit cleanly (`UncleanExit` values; task 109).
    case stabilityUncleanExit
    /// How a child process of a kind ended (`ChildExit` values; task 109).
    case stabilityChildExit(ProcessKind)
    /// A daemon that stopped answering, by the class of its last request (`MethodClass` position; task 109).
    case daemonUnresponsive
    /// Main-thread blocking violations: one sample of 1 per new main-thread call site the blocking detector's drain
    /// hands the hang report sink, so with `stability.launch` the sites per launch. Debug and the Nightly built with
    /// `CMUX_BLOCKING_CHECKS` only (task 089).
    case blockingViolations
}

extension HistogramID: CaseIterable {
    /// Every histogram of the catalog, each dimension value its own entry.
    public static var allCases: [HistogramID] {
        var all: [HistogramID] = [
            .resizeFrame, .frameInterval, .mainTurn, .mainQueueDelay, .hangOver250PerHour, .launchPageins,
            .memoryTotal, .memoryHiddenWorkspace, .diskIdleWrite, .cefPump, .cefHelperExit, .rendererUnresponsive,
            .daemonDispatchQueue, .automationMainQueue, .automationBlockedPerson, .runtimeBusy, .remoteInputToPresent,
            .stabilityLaunch, .stabilityActiveSeconds, .stabilityUncleanExit, .daemonUnresponsive, .blockingViolations,
        ]
        for kind in CongestionKind.allCases {
            for stage in StartupStage.allCases { all.append(.mainCongestion(kind, stage)) }
        }
        all += KeyTarget.allCases.map(Self.keyFrame)
        all += EchoRoute.allCases.map(Self.keyEchoFrame)
        all += InputKind.allCases.map(Self.inputFrame)
        all += FrameSequence.allCases.map(Self.smoothnessDroppedPercent)
        all += HangLane.allCases.map(Self.hangThreadHung)
        all += Entrypoint.allCases.map(Self.actionCommit)
        all += Command.allCases.map(Self.actionCommand)
        all += Command.allCases.map(Self.actionMissedFrames)
        all += LaunchTemperature.allCases.map(Self.launchFirstFrame)
        all += WakeupSource.allCases.map(Self.idleWakeups)
        all += ProcessKind.allCases.map(Self.memory)
        all += ProcessKind.allCases.map(Self.cpu)
        all += Page.allCases.map(Self.webviewINP)
        all += Page.allCases.map(Self.webviewLoAF)
        all += Page.allCases.map(Self.webviewJSErrors)
        all += Chromium.allCases.map(Self.chromium)
        all += MethodClass.allCases.map(Self.daemonRequest)
        all += MethodClass.allCases.map(Self.automationRequest)
        all += ProcessKind.allCases.map(Self.stabilityChildExit)
        return all
    }
}

extension HistogramID {
    /// The name a report and `cmux metrics` show: `<family>.<dimension>`, never changed once shipped.
    public var name: String {
        switch self {
        case let .keyFrame(target): "key.frame." + target.rawValue
        case let .keyEchoFrame(route): "key.echo_frame." + route.rawValue
        case let .inputFrame(kind): "input.frame." + kind.rawValue
        case .resizeFrame: "resize.frame"
        case let .smoothnessDroppedPercent(sequence): "smoothness.dropped_pct." + sequence.rawValue
        case .frameInterval: "frame.interval"
        case .mainTurn: "main.turn"
        case .mainQueueDelay: "main.queue_delay"
        case let .mainCongestion(kind, stage): "main.congestion." + kind.rawValue + "." + stage.rawValue
        case .hangOver250PerHour: "hang.over250.per_hour"
        case let .hangThreadHung(lane): "hang.thread_hung." + lane.rawValue
        case let .actionCommit(entrypoint): "action.commit." + entrypoint.rawValue
        case let .actionCommand(command): "action." + command.rawValue
        case let .actionMissedFrames(command): "action.missed_frames." + command.rawValue
        case let .launchFirstFrame(temperature): "launch.first_frame." + temperature.rawValue
        case .launchPageins: "launch.pageins"
        case let .idleWakeups(source): "idle.wakeups." + source.rawValue
        case let .memory(kind): "memory." + kind.rawValue + "_kib"
        case .memoryTotal: "memory.total_kib"
        case .memoryHiddenWorkspace: "memory.hidden_workspace_kib"
        case let .cpu(kind): "cpu." + kind.rawValue + "_pct"
        case .diskIdleWrite: "disk.idle_write_kib_per_min"
        case .cefPump: "cef.pump"
        case .cefHelperExit: "cef.helper_exit"
        case .rendererUnresponsive: "renderer.unresponsive_ms"
        case let .webviewINP(page): "webview.inp." + page.rawValue
        case let .webviewLoAF(page): "webview.loaf_ms." + page.rawValue
        case let .webviewJSErrors(page): "webview.js_errors." + page.rawValue
        case let .chromium(histogram): "chromium." + histogram.rawValue
        case let .daemonRequest(methodClass): "daemon.request." + methodClass.rawValue
        case .daemonDispatchQueue: "daemon.dispatch.queue_us"
        case let .automationRequest(methodClass): "automation.request." + methodClass.rawValue
        case .automationMainQueue: "automation.main_queue_us"
        case .automationBlockedPerson: "automation.blocked_person"
        case .runtimeBusy: "runtime.busy_ms"
        case .remoteInputToPresent: "remote.input_to_present"
        case .stabilityLaunch: "stability.launch"
        case .stabilityActiveSeconds: "stability.active_seconds"
        case .stabilityUncleanExit: "stability.unclean_exit"
        case let .stabilityChildExit(kind): "stability.child_exit." + kind.rawValue
        case .daemonUnresponsive: "daemon.unresponsive"
        case .blockingViolations: "blocking.violations"
        }
    }

    /// What a sample counts.
    public var unit: Unit {
        switch self {
        case .keyFrame, .keyEchoFrame, .inputFrame, .resizeFrame, .frameInterval, .mainTurn, .mainQueueDelay,
             .actionCommit, .actionCommand, .cefPump, .daemonRequest, .daemonDispatchQueue, .automationRequest,
             .automationMainQueue, .automationBlockedPerson, .remoteInputToPresent:
            .microseconds
        case .mainCongestion, .launchFirstFrame, .rendererUnresponsive, .webviewINP, .webviewLoAF, .runtimeBusy: .milliseconds
        case .memory, .memoryTotal, .memoryHiddenWorkspace, .diskIdleWrite: .kibibytes
        case .smoothnessDroppedPercent, .cpu: .percent
        case .hangOver250PerHour, .hangThreadHung, .actionMissedFrames, .launchPageins, .idleWakeups, .webviewJSErrors,
             .stabilityLaunch, .stabilityActiveSeconds, .blockingViolations:
            .count
        case .cefHelperExit, .stabilityUncleanExit, .stabilityChildExit, .daemonUnresponsive: .enumeration
        case .chromium: .chromium
        }
    }

    /// The bucket layout. Log-linear layouts have 4 buckets per power of two from 1 to the maximum
    /// (task 052 and the Rust writer, task 131, share it); percent and enumeration layouts have one
    /// bucket per value.
    public var layout: Layout {
        switch self {
        case .cefHelperExit: return .enumeration(valueCount: 256)
        case .stabilityUncleanExit: return .enumeration(valueCount: UncleanExit.allCases.count)
        case .stabilityChildExit: return .enumeration(valueCount: ChildExit.allCases.count)
        case .daemonUnresponsive: return .enumeration(valueCount: MethodClass.allCases.count)
        default: break
        }
        switch unit {
        case .microseconds: return .logLinear(maximum: 60_000_000)
        case .milliseconds: return .logLinear(maximum: 3_600_000)
        case .kibibytes: return .logLinear(maximum: 256 * 1024 * 1024)
        case .count: return .logLinear(maximum: 1_000_000)
        case .percent: return .linear(maximum: 100)
        case .enumeration: return .enumeration(valueCount: 1)
        case .chromium: return .chromium
        }
    }

    /// Who answers for this histogram (the program's owner names, plans/cmux-next/OWNERS.md).
    public var owner: StaticString {
        switch self {
        case .keyFrame, .keyEchoFrame, .inputFrame: "PL-typing"
        case .resizeFrame, .smoothnessDroppedPercent, .frameInterval: "PL-motion-core"
        case .mainTurn, .mainQueueDelay, .mainCongestion, .actionCommit, .actionCommand, .actionMissedFrames,
             .launchFirstFrame, .launchPageins, .idleWakeups, .automationRequest, .automationMainQueue,
             .automationBlockedPerson, .blockingViolations:
            "Performance Lead"
        case .cefPump: "PL-cef-tab"
        case .daemonRequest, .daemonDispatchQueue, .runtimeBusy, .daemonUnresponsive: "PL-daemon"
        case .hangOver250PerHour, .hangThreadHung, .memory, .memoryTotal, .memoryHiddenWorkspace, .cpu, .diskIdleWrite,
             .cefHelperExit, .rendererUnresponsive, .webviewINP, .webviewLoAF, .webviewJSErrors, .chromium,
             .remoteInputToPresent, .stabilityLaunch, .stabilityActiveSeconds, .stabilityUncleanExit,
             .stabilityChildExit:
            "PL-telemetry"
        }
    }

    /// When the histogram stops recording unless its owner renews it (Chrome's `expires_after`). The
    /// latency, launch, hang and stability histograms never expire; the exploratory ones end 2027-04-30.
    public var expiry: Expiry {
        switch self {
        case .mainCongestion, .memoryHiddenWorkspace, .diskIdleWrite, .webviewLoAF, .webviewJSErrors, .chromium,
             .automationBlockedPerson, .runtimeBusy, .blockingViolations, .actionMissedFrames:
            .after(year: 2027, month: 4, day: 30)
        default: .never
        }
    }
}
