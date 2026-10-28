import CmuxNextSettings
import CmuxNextSignposts
import Foundation
public import CmuxNextTrace
import CmuxNextWakeups

/// `trace.start`, `trace.stop` and `trace.status` (plans/cmux-next/chrome-parity/p09-observability.md task 020,
/// section 3C): one Release trace recording across the app's ring, the daemon and its children (holder,
/// terminal hosts, acpmux, task 015), Chromium (task 051) and the typing flows (task 019), with the recording
/// indicator (task 133) up while it runs and a cap that stops a forgotten one.
///
/// Chrome's tracing service works the same way (services/tracing/perfetto/consumer_host.cc,
/// base/trace_event/trace_config.h): a consumer names categories and a duration, never a file; each producer
/// records into its own buffer; one session runs at a time; and `TraceConfig`'s duration ends a session nobody
/// stopped. Here every process picks its own ring file, so no parameter is a path or a command, and a
/// parameter this method does not know is refused rather than ignored.
///
/// Access (risk:high, skills/cmux-socket-policy/references/remote-relay-authorization.md): the socket admits
/// the same user in both `cmuxOnly` and `automation` modes, and these methods serve both. A caller that acts for
/// a remote relay (`origin: "remote"`) or for a cmux app (`callerApp`) is refused before anything runs: no
/// relay allowlists these methods, since a recording reads local timing and its replies name local files.
/// Per-key records need `keys: true`, and secure keyboard entry turns them off (task 128).
///
/// ```swift
/// let trace = TraceControl(parts: TraceControlParts(app: RuntimeTraceRecording(blackBox: box, work: work),
///                                                  secureInput: secureInput))
/// router.register(trace.methods)
/// ```
public actor TraceControl {
    typealias JSONValue = CmuxNextSettings.JSONValue

    /// The longest recording, in seconds, and the cap of a start that names none: a recording nobody stops
    /// ends after it.
    public static let maxSeconds = 600
    /// Each method's deadline: a start maps the recording ring once and waits for the daemon's children
    /// (3 s in task 015) and Chromium.
    public static let deadline: Duration = .seconds(15)

    private let parts: TraceControlParts
    /// The cap's one deadline.
    private let cap: DemandTimer
    /// The start time `trace.status` reports.
    private let clock: TraceClock
    private var phase: Phase = .idle
    /// The last finished recording's stop reply, with what stopped it.
    private var lastStop: JSONValue?

    /// The trace methods over `parts`.
    ///
    /// - Parameters:
    ///   - parts: The rings and processes a recording reaches.
    ///   - clock: The clock of the cap (tests inject a manual one).
    ///   - traceClock: The clock of the start time in `trace.status`.
    public init(parts: TraceControlParts, clock: any Clock<Duration> = ContinuousClock(), traceClock: TraceClock = TraceClock()) {
        self.parts = parts
        cap = DemandTimer(owner: "trace.cap", clock: clock)
        self.clock = traceClock
    }

    /// `trace.start`, `trace.stop` and `trace.status`, for ``ControlRouter/register(_:)``.
    public nonisolated var methods: [ControlMethod] {
        [
            .async("trace.start") { [self] call in try await start(call) }.withDeadline(.fixed(Self.deadline)),
            .async("trace.stop") { [self] call in try await stop(call) }.withDeadline(.fixed(Self.deadline)),
            .async("trace.status") { [self] call in try await status(call) }.withDeadline(.fixed(Self.deadline)),
        ]
    }

    // MARK: - Methods

    /// `trace.start {categories?, seconds_cap?, chromium?, keys?}`.
    func start(_ call: ControlCall) async throws -> JSONValue {
        try Self.admit(call, allowing: StartOptions.names)
        let options = try StartOptions(call.params)
        switch phase {
        case .idle: break
        case .recording: throw Self.failure("already_recording", ControlStrings.text("control.error.traceRecording", "a trace recording is already running"))
        case .changing: throw Self.busy
        }
        phase = .changing
        // Secure keyboard entry (a password prompt) wins over `keys: true`: no per-key record while it is on.
        let secureInput = options.keys && parts.secureInput.isSecureInputActive
        let keys = options.keys && !secureInput
        let recording = Recording(options: options, keys: keys, startedNanos: clock.nowNanos())
        var reply: [String: JSONValue] = [
            "recording": true,
            "seconds_cap": JSONValue(options.seconds),
            "categories": .array(options.categoryNames(keys: keys).map(JSONValue.string)),
            "keys": .bool(keys),
        ]
        if secureInput { reply["keys_refused"] = "secure_input" }
        let prepared = await parts.app.prepare()
        reply["app"] = prepared ? Self.json(parts.app.start(options.request(keys: keys))) : Self.untraced("no_recording_ring")
        if keys { parts.keyFlows?.setKeyFlows(true) }
        reply["key_flows"] = .string(!keys ? "off" : parts.keyFlows == nil ? "unsupported" : "on")
        reply["daemon"] = await Self.reply(of: parts.daemon) { try await $0.send(.start(categories: options.daemonCategories, keys: keys)) }
        if options.chromium { reply["chromium"] = await Self.reply(of: parts.chromium) { try await $0.start() } }
        phase = .recording(recording)
        await parts.indicator?.show { [weak self] in _ = await self?.finish(reason: "indicator") }
        cap.schedule(after: .seconds(options.seconds)) { [weak self] in _ = await self?.finish(reason: "cap") }
        return .object(reply)
    }

    /// `trace.stop`: every part stops; the reply names each ring's file.
    func stop(_ call: ControlCall) async throws -> JSONValue {
        try Self.admit(call, allowing: [])
        switch phase {
        case .recording: return await finish(reason: "request") ?? .null
        case .idle: throw Self.failure("not_recording", ControlStrings.text("control.error.traceNotRecording", "no trace recording is running"))
        case .changing: throw Self.busy
        }
    }

    /// `trace.status`: whether a recording runs, each part's state, and how the last one stopped.
    func status(_ call: ControlCall) async throws -> JSONValue {
        try Self.admit(call, allowing: [])
        var reply: [String: JSONValue] = ["recording": false, "app": Self.json(parts.app.status)]
        switch phase {
        case .idle: break
        case .changing: reply["changing"] = true
        case .recording(let recording):
            reply["recording"] = true
            reply["seconds_cap"] = JSONValue(recording.options.seconds)
            reply["started_uptime_ns"] = .number(Double(recording.startedNanos))
            reply["keys"] = .bool(recording.keys)
            reply["categories"] = .array(recording.options.categoryNames(keys: recording.keys).map(JSONValue.string))
            reply["chromium"] = .bool(recording.options.chromium)
        }
        reply["daemon"] = await Self.reply(of: parts.daemon) { try await $0.send(.status) }
        if let lastStop { reply["last_stop"] = lastStop }
        return .object(reply)
    }

    /// Stops the running recording in every part it reached; nil when none runs (a cap or indicator stop that
    /// a `trace.stop` already answered).
    ///
    /// - Parameter reason: What stopped it: `request`, `cap` or `indicator`.
    @discardableResult
    func finish(reason: String) async -> JSONValue? {
        guard case .recording(let recording) = phase else { return nil }
        phase = .changing
        cap.cancel()
        var reply: [String: JSONValue] = ["recording": false, "stopped_by": .string(reason), "app": Self.json(parts.app.stop())]
        if recording.keys { parts.keyFlows?.setKeyFlows(false) }
        reply["daemon"] = await Self.reply(of: parts.daemon) { try await $0.send(.stop) }
        if recording.options.chromium { reply["chromium"] = await Self.reply(of: parts.chromium) { try await $0.stop() } }
        await parts.indicator?.hide()
        phase = .idle
        lastStop = .object(reply)
        return .object(reply)
    }

    // MARK: - Policy and replies

    /// Refuses a relay or app caller, then any parameter outside `names` and the router's own (`origin`,
    /// `caller`, `after`): none of these methods takes a path or a command.
    static func admit(_ call: ControlCall, allowing names: Set<String>) throws {
        let origin = try ControlOrigin().validated(call.params["origin"], connection: call.connection)
        guard origin != "remote", call.request.callerApp == nil else {
            throw failure("forbidden", ControlStrings.format("control.error.traceRemote", "%@ serves local callers only, never a remote relay or a cmux app",
                                                             call.method))
        }
        for name in call.params.keys.sorted() where !names.contains(name) && !routerParams.contains(name) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@", call.method, name),
                                             data: ["param": .string(name)])
        }
    }

    /// Parameters the router and the CLI add to any request.
    static let routerParams: Set<String> = ["origin", "caller", "after"]

    static var busy: ControlError { failure("busy", ControlStrings.text("control.error.traceBusy", "a trace start or stop is still running")) }

    static func failure(_ code: String, _ message: String) -> ControlError {
        ControlError(code: code, message: message)
    }

    /// The app ring's state as a reply member.
    static func json(_ status: TraceRuntime.RecordingStatus) -> JSONValue {
        switch status {
        case .idle: ["state": "idle"]
        case .recording(let path, let bytes): ["state": "recording", "path": .string(path), "recording_bytes": JSONValue(bytes)]
        case .stopped(let path, let bytes): ["state": "stopped", "path": .string(path), "recording_bytes": JSONValue(bytes)]
        }
    }

    static func untraced(_ reason: String) -> JSONValue {
        ["state": "untraced", "reason": .string(reason)]
    }

    /// One part's answer: its reply, `unsupported` when this build has no such part, or its error. A part
    /// that fails never stops the others (task 015 reports each child the same way).
    static func reply<Part: Sendable>(of part: Part?, _ body: (Part) async throws -> JSONValue) async -> JSONValue {
        guard let part else { return untraced("unsupported") }
        do {
            return try await body(part)
        } catch let error as ControlError {
            return ["state": "error", "error": .string(error.code), "message": .string(error.message)]
        } catch {
            return ["state": "error", "error": .string(String(describing: error))]
        }
    }
}

extension TraceControl {
    /// A daemon trace call (task 015's commands; no path parameter).
    public enum DaemonCommand: Sendable, Equatable {
        /// `trace-start`: `categories` nil is the daemon's recording set.
        case start(categories: [String]?, keys: Bool)
        /// `trace-stop`.
        case stop
        /// `trace-status`.
        case status
    }

    /// A recording's phase: one start or stop changes it at a time.
    enum Phase {
        case idle
        /// A start or a stop is reaching the parts.
        case changing
        case recording(Recording)
    }

    /// The running recording.
    struct Recording {
        let options: StartOptions
        /// Per-key records and key flows are on (`keys: true` with secure input off).
        let keys: Bool
        /// ``TraceClock`` nanoseconds at the start.
        let startedNanos: UInt64
    }

    /// `trace.start`'s parameters, checked.
    struct StartOptions {
        /// Every parameter `trace.start` reads.
        static let names: Set<String> = ["categories", "seconds_cap", "chromium", "keys"]

        /// The requested categories; nil: every recording category (``SignpostCategory/isBlackBoxDefault`` false).
        let categories: [SignpostCategory]?
        let seconds: Int
        let chromium: Bool
        let keys: Bool

        init(_ params: [String: CmuxNextSettings.JSONValue]) throws {
            chromium = try Self.flag("chromium", params)
            keys = try Self.flag("keys", params)
            switch params["seconds_cap"] {
            case nil, .null?: seconds = TraceControl.maxSeconds
            case let value?:
                guard let whole = value.intValue, (1 ... TraceControl.maxSeconds).contains(whole) else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.traceSecondsCap", "seconds_cap must be a whole number from 1 to %@",
                                                                           String(TraceControl.maxSeconds)))
                }
                seconds = whole
            }
            switch params["categories"] {
            case nil, .null?: categories = nil
            case .array(let items)?:
                var parsed: [SignpostCategory] = []
                for item in items {
                    guard let name = item.stringValue else {
                        throw ControlError.invalidParams(ControlStrings.format("control.error.mustBeString", "%@ must be a string", "categories[]"))
                    }
                    guard let category = SignpostCategory(rawValue: name) else {
                        throw ControlError.invalidParams(ControlStrings.format("control.error.traceUnknownCategory", "unknown trace category %@", name),
                                                         data: ["category": .string(name)])
                    }
                    parsed.append(category)
                }
                categories = parsed
            case _?:
                throw ControlError.invalidParams(ControlStrings.text("control.error.traceCategoriesShape", "categories must be an array of category names"))
            }
            if categories?.contains(.key) == true, !keys {
                throw ControlError.invalidParams(ControlStrings.text("control.error.traceKeyCategory",
                                                                     "the key category records the timing of each key: ask for it with keys: true"))
            }
        }

        private static func flag(_ name: String, _ params: [String: CmuxNextSettings.JSONValue]) throws -> Bool {
            guard let value = params[name], !value.isNull else { return false }
            guard let flag = value.boolValue else {
                throw ControlError.invalidParams(ControlStrings.format("control.error.boolShape", "%@ must be true or false", name))
            }
            return flag
        }

        /// The categories the recording adds.
        private var added: [SignpostCategory] {
            categories ?? SignpostCategory.allCases.filter { !$0.isBlackBoxDefault }
        }

        /// The names `trace.start` and `trace.status` report: the added categories, with `key` only with `keys`.
        func categoryNames(keys: Bool) -> [String] {
            var names = added.filter { $0 != .key }.map(\.rawValue)
            if keys { names.append(SignpostCategory.key.rawValue) }
            return names
        }

        /// What the daemon's `trace-start` names: nil for its own default set (task 015's `RECORDING`). The
        /// daemon adds `key` itself for `keys: true`, and refuses it without.
        var daemonCategories: [String]? {
            categories.map { $0.filter { $0 != .key }.map(\.rawValue) }
        }

        /// The app ring's request: the added categories' bits, the app role's ring and `keys`.
        func request(keys: Bool) -> TraceRuntime.RecordingRequest {
            let mask = TraceCategories(added.map { TraceCategories(bit: $0.traceBit) }).rawValue
            let sizes = TraceRuntime.Role.app.recordingSizes
            return TraceRuntime.RecordingRequest(categoryMask: mask, recordCapacity: sizes.chunkCount * TraceRing.recordsPerChunk, keys: keys)
        }
    }
}
