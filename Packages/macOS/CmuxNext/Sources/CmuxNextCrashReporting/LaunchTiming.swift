public import Foundation
public import Sentry

/// One sampled launch's field timing (startup-tti): how long a real launch took to its first window frame and to
/// its first interaction, sent as one Sentry transaction under the crash reports' consent (``CrashReportingPolicy``:
/// the `sendAnonymousTelemetry` choice, `DisableTelemetry` winning, DEV builds off unless `CMUX_NEXT_DEV_SENTRY=1`).
///
/// The numbers are the launch marks `scripts/measure/launch-ready.sh` reads, on the same clock (milliseconds since
/// the process started), so a field number and a bench number mean the same thing:
/// - first frame: `first_window_frame_committed`;
/// - first interaction: the front surface taking keys: `window_usable` (Home's message field has the keyboard),
///   else the restored front chat live (``priorChatLiveMs``, `agent_pane.transport_open`), else the restored
///   terminal attached (`terminal.attach_end`). The bench's interaction is a typed key taken; a person's first key
///   comes when they type, so the field reads the moment the app could take it.
///
/// The payload is these fields and nothing else (``tags``, ``measurements``, the release and environment):
/// no content, path, name, install id or other identifier. ``CrashReporter/options()`` strips every other field
/// the SDK adds (``strip(_:)``).
public nonisolated struct LaunchTiming: Sendable, Equatable {
    /// The transaction's name, which the reader queries (`transaction:cmux.launch`).
    public static let transactionName = "cmux.launch"
    /// The transaction's operation.
    public static let operation = "app.launch"
    /// The share of launches that send one (10%).
    public static let sampleRate = 0.1
    /// The measurement names (`measurements.launch_first_frame`, `measurements.launch_first_interaction`).
    public static let firstFrameMeasurement = "launch_first_frame"
    public static let firstInteractionMeasurement = "launch_first_interaction"
    /// The tag names.
    public static let kindTag = "launch_kind"
    public static let workspacesTag = "workspaces"

    /// A cold launch is the first of this build's files (a new install or update not pre-warmed); warm is a relaunch.
    public enum Kind: String, Sendable, Equatable {
        case cold
        case warm
    }

    /// How many workspaces the launch restored, as a coarse bucket.
    public enum WorkspaceBucket: String, Sendable, Equatable, CaseIterable {
        case none = "0"
        case few = "1-9"
        case some = "10-49"
        case many = "50-199"
        case huge = "200+"

        public init(count: Int) {
            switch count {
            case ..<1: self = .none
            case 1...9: self = .few
            case 10...49: self = .some
            case 50...199: self = .many
            default: self = .huge
            }
        }
    }

    /// Process start to the first window frame committed, ms.
    public let firstFrameMs: Double
    /// Process start to the first interaction, ms; nil when no front surface took keys by the record.
    public let firstInteractionMs: Double?
    public let kind: Kind
    public let workspaces: WorkspaceBucket

    public init(firstFrameMs: Double, firstInteractionMs: Double?, kind: Kind, workspaces: WorkspaceBucket) {
        self.firstFrameMs = firstFrameMs
        self.firstInteractionMs = firstInteractionMs
        self.kind = kind
        self.workspaces = workspaces
    }

    /// The timing of a launch whose marks are `marks` (name to ms since process start); nil without a first frame.
    /// - Parameters:
    ///   - priorChatLiveMs: the restored front chat drawn and live (`LaunchPriorChat`), when it was.
    ///   - firstOfBuild: this is the first launch of this build's files (`LaunchTimesRecord.firstLaunchOfBuild`).
    ///   - prewarmed: the updater ran this build once before this launch (`LaunchTimesRecord.prewarmed`).
    ///   - workspaceCount: the workspaces the launch restored.
    public init?(marks: [String: Double], priorChatLiveMs: Double?, firstOfBuild: Bool, prewarmed: Bool, workspaceCount: Int) {
        guard let frame = marks["first_window_frame_committed"], frame.isFinite, frame >= 0 else { return nil }
        let interaction = marks["window_usable"] ?? priorChatLiveMs ?? marks["terminal.attach_end"]
        self.init(firstFrameMs: Self.round(frame), firstInteractionMs: interaction.flatMap { $0.isFinite && $0 >= 0 ? Self.round($0) : nil },
                  kind: firstOfBuild && !prewarmed ? .cold : .warm, workspaces: WorkspaceBucket(count: workspaceCount))
    }

    /// The transaction's tags: the launch kind and the workspace bucket, nothing else.
    public var tags: [String: String] {
        [Self.kindTag: kind.rawValue, Self.workspacesTag: workspaces.rawValue]
    }

    /// The transaction's measurements, in milliseconds.
    public var measurements: [String: Double] {
        var values = [Self.firstFrameMeasurement: firstFrameMs]
        if let firstInteractionMs { values[Self.firstInteractionMeasurement] = firstInteractionMs }
        return values
    }

    /// Whether this launch sends its timing: Sentry runs (the crash reports' consent) and the roll (0 to 1) falls
    /// in ``sampleRate``.
    public static func samples(policy: CrashReportingPolicy, roll: Double) -> Bool {
        policy.shouldStart && roll >= 0 && roll < sampleRate
    }

    /// Whether `event` is a launch timing transaction.
    public static func isLaunchTiming(_ event: Event) -> Bool {
        event.type == "transaction" && event.transaction == transactionName
    }

    /// `event` (a launch timing transaction) with every field the SDK added beyond the fixed ones removed: no user
    /// (the SDK's default is the install id), device, OS, app or culture context, breadcrumbs, extra, debug images,
    /// modules, server name or request. Only the fixed tags stay; the release, environment, timestamps and trace
    /// ids (random per event) stay, and the measurements the transaction serializes.
    public static func strip(_ event: Event) -> Event {
        event.user = nil
        event.context = nil
        event.extra = nil
        event.breadcrumbs = nil
        event.debugMeta = nil
        event.modules = nil
        event.serverName = nil
        event.request = nil
        event.threads = nil
        event.exceptions = nil
        event.stacktrace = nil
        event.fingerprint = nil
        event.dist = nil
        let allowed: Set<String> = [kindTag, workspacesTag]
        event.tags = event.tags?.filter { allowed.contains($0.key) }
        return event
    }

    /// Captures this timing as one `cmux.launch` transaction on the running SDK. The caller has checked consent
    /// (``CrashReporter/sendLaunchTiming(_:)``); a test that started the SDK itself calls it directly.
    public func capture() {
        let transaction = SentrySDK.startTransaction(name: Self.transactionName, operation: Self.operation)
        for (key, value) in tags { transaction.setTag(value: value, key: key) }
        for (name, value) in measurements {
            transaction.setMeasurement(name: name, value: NSNumber(value: value), unit: MeasurementUnitDuration.millisecond)
        }
        transaction.finish()
    }

    private static func round(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }
}

extension CrashReporter {
    /// Sends `timing` as one `cmux.launch` transaction while Sentry runs (the crash reports' consent); nothing
    /// otherwise. The caller decides the sample (``LaunchTiming/samples(policy:roll:)``).
    public func sendLaunchTiming(_ timing: LaunchTiming) {
        guard isStarted else { return }
        timing.capture()
    }

    /// What the launch-times record calls once it is written (startup-tti): with the record's prior chat live time,
    /// whether it is the build's first launch and whether it was pre-warmed, sends this launch's timing from `marks`
    /// when it is sampled and Sentry runs. `workspaceCount` is the workspaces the launch restored.
    public func launchTimingSink(marks: [String: Double], workspaceCount: Int)
        -> @Sendable (_ priorChatLiveMs: Double?, _ firstOfBuild: Bool, _ prewarmed: Bool) -> Void {
        { [self] priorChatLiveMs, firstOfBuild, prewarmed in
            guard let timing = LaunchTiming(marks: marks, priorChatLiveMs: priorChatLiveMs, firstOfBuild: firstOfBuild,
                                            prewarmed: prewarmed, workspaceCount: workspaceCount) else { return }
            sendLaunchTimingIfSampled(timing)
        }
    }

    /// Sends `timing` when this launch is sampled (`roll` in ``LaunchTiming/sampleRate``) and Sentry runs.
    /// - Returns: whether it was sent.
    @discardableResult
    public func sendLaunchTimingIfSampled(_ timing: LaunchTiming, roll: Double = Double.random(in: 0..<1)) -> Bool {
        guard isStarted, LaunchTiming.samples(policy: policy, roll: roll) else { return false }
        sendLaunchTiming(timing)
        return true
    }
}
