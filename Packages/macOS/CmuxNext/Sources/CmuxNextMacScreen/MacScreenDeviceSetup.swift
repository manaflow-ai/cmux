public import CmuxNextDaemon
public import CmuxNextDaemonService
import Foundation
public import Observation

/// Set up cmux and Start cmux on one of the user's own Macs, from Screen Sharing: each is one
/// `device-setup {device, verb}` request to this app's own daemon (``DeviceSetupRequest``), which runs
/// every step itself (cmux-tui `devices`, the steps of `cmux device setup|start`). The app starts no
/// process for it. This file only reads the step events and the reply and keeps what each device's
/// run has said so far, for the device rows and the offline card to draw.
///
/// Each step (`device-setup-step`) carries the CLI's step line, `{"device","step","state","detail",
/// "fix"}` with `state` one of `ok`, `changed`, `warn`, `fail`, `skip`; the reply is the summary
/// `{"device","summary","changed":[…]}`. A daemon that answers unknown command is too old: the
/// buttons hide.
public nonisolated enum MacScreenDeviceVerb: String, CaseIterable, Sendable {
    /// Installs or updates cmux NIGHTLY and its daemon on the Mac (`cmux device setup`).
    case setup
    /// Opens cmux on the Mac (`cmux device start`).
    case start
}

/// One step line of a run.
public nonisolated struct MacScreenDeviceStep: Equatable, Sendable, Decodable {
    public nonisolated enum State: String, Equatable, Sendable, Decodable {
        /// Nothing to do.
        case ok
        /// The step changed something on the Mac (installed, updated, opened).
        case changed
        /// Done, but not fully; `fix` says what a person can do.
        case warn
        /// The step failed; `fix` says what a person can do.
        case fail
        /// Not run (a step it depends on failed, or it was not needed).
        case skip

        /// A state this build does not know reads as a warning: shown, never a pass.
        public init(from decoder: any Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .warn
        }
    }

    public var device: String
    public var step: String
    public var state: State
    public var detail: String
    /// A sentence for a person; never a command the app runs.
    public var fix: String?

    public init(device: String, step: String, state: State, detail: String = "", fix: String? = nil) {
        self.device = device
        self.step = step
        self.state = state
        self.detail = detail
        self.fix = fix
    }

    nonisolated enum CodingKeys: String, CodingKey { case device, step, state, detail, fix }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        step = try c.decode(String.self, forKey: .step)
        state = try c.decode(State.self, forKey: .state)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The last line of a run.
public nonisolated struct MacScreenDeviceSummary: Equatable, Sendable, Decodable {
    public var device: String
    public var summary: String
    /// The steps that changed something.
    public var changed: [String]

    public init(device: String, summary: String, changed: [String] = []) {
        self.device = device
        self.summary = summary
        self.changed = changed
    }

    nonisolated enum CodingKeys: String, CodingKey { case device, summary, changed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        summary = try c.decode(String.self, forKey: .summary)
        changed = try c.decodeIfPresent([String].self, forKey: .changed) ?? []
    }
}

/// One step event or the reply of a run, in the CLI's line shapes.
public nonisolated enum MacScreenDeviceLine: Equatable, Sendable {
    case step(MacScreenDeviceStep)
    case summary(MacScreenDeviceSummary)

    /// Reads one line; nil for a blank line, a log line or a line type this build does not know.
    public static func parse(_ line: String) -> MacScreenDeviceLine? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") else { return nil }
        return parse(data: Data(text.utf8))
    }

    /// Reads one JSON object (a step event's fields, or the reply); nil for any other shape.
    static func parse(data: Data) -> MacScreenDeviceLine? {
        let decoder = JSONDecoder()
        if let summary = try? decoder.decode(MacScreenDeviceSummary.self, from: data) { return .summary(summary) }
        if let step = try? decoder.decode(MacScreenDeviceStep.self, from: data) { return .step(step) }
        return nil
    }
}

/// The verbs this app's daemon runs: both, until it refuses one as an unknown command.
public nonisolated struct MacScreenDeviceVerbs: Equatable, Sendable {
    public var known: Set<MacScreenDeviceVerb>

    public init(_ known: Set<MacScreenDeviceVerb>) { self.known = known }

    /// Every verb (a daemon not yet known to refuse them).
    public static let all = MacScreenDeviceVerbs(Set(MacScreenDeviceVerb.allCases))

    public func has(_ verb: MacScreenDeviceVerb) -> Bool { known.contains(verb) }
}

/// Why a run ended without its reply: the daemon refused it, or the request failed.
public nonisolated struct MacScreenDeviceRunStop: Error, Equatable, Sendable {
    /// The daemon does not know `device-setup` (an older cmux-tui): the buttons hide.
    public var unknownCommand: Bool
    public var message: String

    public init(unknownCommand: Bool = false, message: String) {
        self.unknownCommand = unknownCommand
        self.message = message
    }
}

/// What one device's run has said so far.
public nonisolated struct MacScreenDeviceRun: Equatable, Sendable {
    public nonisolated enum Phase: Equatable, Sendable {
        case running
        /// Exit 0: no step failed.
        case succeeded
        /// A step failed, or the run stopped; the CLI's last words when no step said why.
        case failed(String)
        /// The daemon does not know the `device-setup` command.
        case needsNewerCmux
    }

    public var verb: MacScreenDeviceVerb
    public var steps: [MacScreenDeviceStep] = []
    public var summary: MacScreenDeviceSummary?
    public var phase: Phase = .running

    public init(verb: MacScreenDeviceVerb, steps: [MacScreenDeviceStep] = [], summary: MacScreenDeviceSummary? = nil, phase: Phase = .running) {
        self.verb = verb
        self.steps = steps
        self.summary = summary
        self.phase = phase
    }

    public var isRunning: Bool { phase == .running }

    /// Takes one line in: a step replaces an earlier line of the same step (a step can report again).
    public mutating func take(_ line: MacScreenDeviceLine) {
        switch line {
        case let .step(step):
            if let at = steps.firstIndex(where: { $0.step == step.step }) { steps[at] = step } else { steps.append(step) }
        case let .summary(summary):
            self.summary = summary
        }
    }

    /// The run ended: `stop` nil is the daemon's reply.
    public mutating func end(_ stop: MacScreenDeviceRunStop?) {
        guard let stop else {
            phase = steps.contains { $0.state == .fail } ? .failed("") : .succeeded
            return
        }
        if stop.unknownCommand, steps.isEmpty, summary == nil {
            phase = .needsNewerCmux
        } else {
            phase = .failed(steps.contains { $0.state == .fail } ? "" : stop.message)
        }
    }
}

/// What a device row (and the offline card) offers: Set up cmux, Start cmux, and the run to draw.
public nonisolated struct MacScreenDeviceSetupRow: Equatable, Sendable {
    /// Set Up cmux (every Mac, while the daemon runs `device-setup`).
    public var showsSetup: Bool
    /// Start cmux on NAME (an offline Mac, while the daemon runs `device-setup`).
    public var showsStart: Bool
    public var run: MacScreenDeviceRun?

    public init(showsSetup: Bool = false, showsStart: Bool = false, run: MacScreenDeviceRun? = nil) {
        self.showsSetup = showsSetup
        self.showsStart = showsStart
        self.run = run
    }

    /// No button and no run (a phone, no daemon, a daemon that refused the verbs).
    public static let none = MacScreenDeviceSetupRow()

    /// The buttons a device shows. Only a Mac: a phone has no cmux to set up. A verb the daemon
    /// refused (or no daemon, `verbs` nil) shows no button; Start only while the Mac is offline, and
    /// while a Start runs (its row may come online before the run ends).
    public static func make(isMac: Bool, online: Bool, verbs: MacScreenDeviceVerbs?, run: MacScreenDeviceRun?) -> MacScreenDeviceSetupRow {
        guard isMac else { return .none }
        let verbs = verbs ?? MacScreenDeviceVerbs([])
        let starting = run?.verb == .start && run?.isRunning == true
        return MacScreenDeviceSetupRow(showsSetup: verbs.has(.setup),
                                       showsStart: verbs.has(.start) && (!online || starting),
                                       run: run)
    }

    /// The row for a device whose host may block this Mac: a blocked host offers no Set Up cmux (it
    /// refuses the request, and a blocked row has no More menu). Start stays; it shows only while offline.
    public func blocking(allowsRequests: Bool) -> MacScreenDeviceSetupRow {
        guard !allowsRequests else { return self }
        var row = self
        row.showsSetup = false
        return row
    }

    /// Whether a button of `verb` can be pressed now (no run of either verb in flight).
    public func canRun(_ verb: MacScreenDeviceVerb) -> Bool {
        run?.isRunning != true && (verb == .setup ? showsSetup : showsStart)
    }
}

/// The runs of Set up cmux and Start cmux, by hub device id, for every Screen Sharing page and card
/// of the app. The app hands it its daemon (``runner``); without one no button shows.
@MainActor @Observable
public final class MacScreenDeviceSetup {
    /// One run of `verb` on the device named `name`: its step lines, then its summary; it ends with
    /// ``MacScreenDeviceRunStop`` when the daemon refuses it, and cancelling the stream stops watching.
    public typealias Runner = @MainActor (_ verb: MacScreenDeviceVerb, _ name: String) -> AsyncThrowingStream<MacScreenDeviceLine, any Error>

    /// The daemon's `device-setup` (the app sets it); nil: none, so no button shows.
    @ObservationIgnored public var runner: Runner? {
        didSet { if runner != nil, verbs == nil { verbs = .all } }
    }
    /// A run of `verb` on device `id` succeeded (the pages read the hub's devices again).
    @ObservationIgnored public var succeeded: @MainActor (_ id: String, _ verb: MacScreenDeviceVerb) -> Void = { _, _ in }
    /// The verbs the daemon runs: every verb once a runner is set, less any it refused.
    public private(set) var verbs: MacScreenDeviceVerbs?
    /// Each device's last run, by hub device id, until dismissed.
    public private(set) var runs: [String: MacScreenDeviceRun] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init(runner: Runner? = nil) {
        self.runner = runner
        if runner != nil { verbs = .all }
    }

    /// The runner of this app's own daemon: one ``DeviceSetupRequest`` per run, its step events (the
    /// side events of `daemon`'s store that name the device) as lines, then its reply. An unknown
    /// command reaches the run as ``MacScreenDeviceRunStop/unknownCommand``.
    public static func runner(daemon: DaemonService) -> Runner {
        { [weak daemon] verb, name in
            AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1024)) { continuation in
                guard let daemon, let connection = daemon.connection else {
                    continuation.finish(throwing: MacScreenDeviceRunStop(message: DaemonError.notConnected.localizedDescription))
                    return
                }
                let events = daemon.store.sideEvents
                let token = events.subscribe { event in
                    guard case let .unknown(eventName, payload) = event, eventName == DeviceSetupRequest.stepEvent,
                          let line = Self.line(payload), case let .step(step) = line, step.device.isEmpty || step.device == name else { return }
                    continuation.yield(line)
                }
                // task-owner: one device-setup request; the stream's end cancels it.
                let request = Task {
                    defer { events.unsubscribe(token) }
                    do {
                        // A setup can download and install the app: the daemon bounds its own steps.
                        let reply = try await connection.request(DeviceSetupRequest(device: name, verb: verb.rawValue), timeout: .seconds(900))
                        if let line = Self.line(reply) { continuation.yield(line) }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: MacScreenDeviceRunStop(unknownCommand: DeviceSetupRequest.isUnknownCommand(error),
                                                                             message: error.localizedDescription))
                    }
                }
                continuation.onTermination = { _ in request.cancel() }
            }
        }
    }

    /// A step event's or reply's fields as a line (nil for any other shape).
    nonisolated static func line(_ value: CmuxNextDaemon.JSONValue) -> MacScreenDeviceLine? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return MacScreenDeviceLine.parse(data: data)
    }

    /// What device `id` shows.
    public func row(id: String, isMac: Bool, online: Bool) -> MacScreenDeviceSetupRow {
        .make(isMac: isMac, online: online, verbs: runner == nil ? nil : verbs, run: runs[id])
    }

    /// Runs `verb` on device `id` (named `name` to the daemon), on a person's press. Ignored while a
    /// run of that device is in flight.
    public func run(_ verb: MacScreenDeviceVerb, id: String, name: String) {
        guard let runner, runs[id]?.isRunning != true else { return }
        runs[id] = MacScreenDeviceRun(verb: verb)
        let lines = runner(verb, name)
        // task-owner: one device run; ends with the daemon's reply, or with dismiss.
        tasks[id] = Task { [weak self] in
            var stop: MacScreenDeviceRunStop?
            do {
                for try await line in lines { self?.runs[id]?.take(line) }
            } catch let failure as MacScreenDeviceRunStop {
                stop = failure
            } catch is CancellationError {
                return
            } catch {
                stop = MacScreenDeviceRunStop(message: error.localizedDescription)
            }
            guard let self, !Task.isCancelled, runs[id]?.isRunning == true else { return }
            runs[id]?.end(stop)
            tasks[id] = nil
            // Both verbs send the same `device-setup` command: a daemon that refuses one refuses both.
            if runs[id]?.phase == .needsNewerCmux { verbs?.known.removeAll() }
            if runs[id]?.phase == .succeeded { succeeded(id, verb) }
        }
    }

    /// Hides device `id`'s finished run (Done), or stops watching one in flight.
    public func dismiss(id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        runs[id] = nil
    }
}
