import Foundation
public import CmuxNextRemote
public import Observation

/// Set up cmux and Start cmux on one of the user's own Macs, from Screen Sharing: each is one run of
/// the bundled `cmux-tui device setup|start <device> --json` (cmux-tui `devices`), whose every step
/// is the CLI's. This file only reads its lines and keeps what each device's run has said so far, for
/// the device rows and the offline card to draw.
///
/// The CLI's lines (`--json`): one per step, `{"device","step","state","detail","fix"}` with `state`
/// one of `ok`, `changed`, `warn`, `fail`, `skip`; then one `{"device","summary","changed":[…]}`.
/// Exit 0 means no step failed. A bundled cmux-tui whose `device help` does not list a verb is too
/// old for it: its button does not show.
public nonisolated enum MacScreenDeviceVerb: String, CaseIterable, Sendable {
    /// Installs or updates cmux NIGHTLY and its daemon on the Mac (`cmux device setup`).
    case setup
    /// Opens cmux on the Mac (`cmux device start`).
    case start

    /// The CLI's arguments for a run on `device` (its name, which `cmux device` resolves).
    public func arguments(device: String) -> [String] {
        ["device", rawValue, device, "--json"]
    }
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

/// One stdout line of a run.
public nonisolated enum MacScreenDeviceLine: Equatable, Sendable {
    case step(MacScreenDeviceStep)
    case summary(MacScreenDeviceSummary)

    /// Reads one line; nil for a blank line, a log line or a line type this build does not know.
    public static func parse(_ line: String) -> MacScreenDeviceLine? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") else { return nil }
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let summary = try? decoder.decode(MacScreenDeviceSummary.self, from: data) { return .summary(summary) }
        if let step = try? decoder.decode(MacScreenDeviceStep.self, from: data) { return .step(step) }
        return nil
    }
}

/// The verbs the bundled cmux-tui runs, read from its `device help` (the usage lists every verb).
public nonisolated struct MacScreenDeviceVerbs: Equatable, Sendable {
    public var known: Set<MacScreenDeviceVerb>

    public init(_ known: Set<MacScreenDeviceVerb>) { self.known = known }

    public func has(_ verb: MacScreenDeviceVerb) -> Bool { known.contains(verb) }

    /// The verbs a usage text lists: each `cmux device VERB…` line's first word, `a|b` naming two.
    public static func parse(usage: String) -> MacScreenDeviceVerbs {
        var known = Set<MacScreenDeviceVerb>()
        for line in usage.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let at = words.firstIndex(where: { $0 == "device" }), at > 0, words[at - 1].hasSuffix("cmux"),
                  words.indices.contains(at + 1) else { continue }
            for name in words[at + 1].split(separator: "|") {
                if let verb = MacScreenDeviceVerb(rawValue: String(name)) { known.insert(verb) }
            }
        }
        return MacScreenDeviceVerbs(known)
    }
}

/// Why a run ended without exit 0: the exit status (nil: it did not start) and its last stderr line.
public nonisolated struct MacScreenDeviceRunStop: Error, Equatable, Sendable {
    public var status: Int32?
    public var message: String

    public init(status: Int32?, message: String) {
        self.status = status
        self.message = message
    }

    /// The CLI did not take the verb (exit 2, its usage): a cmux-tui older than the button.
    public var isUnknownVerb: Bool { status == 2 }
}

/// What one device's run has said so far.
public nonisolated struct MacScreenDeviceRun: Equatable, Sendable {
    public nonisolated enum Phase: Equatable, Sendable {
        case running
        /// Exit 0: no step failed.
        case succeeded
        /// A step failed, or the run stopped; the CLI's last words when no step said why.
        case failed(String)
        /// The bundled cmux-tui does not have the verb.
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

    /// The run ended: `stop` nil is exit 0.
    public mutating func end(_ stop: MacScreenDeviceRunStop?) {
        guard let stop else {
            phase = steps.contains { $0.state == .fail } ? .failed("") : .succeeded
            return
        }
        if stop.isUnknownVerb, steps.isEmpty, summary == nil {
            phase = .needsNewerCmux
        } else {
            phase = .failed(steps.contains { $0.state == .fail } ? "" : stop.message)
        }
    }
}

/// What a device row (and the offline card) offers: Set up cmux, Start cmux, and the run to draw.
public nonisolated struct MacScreenDeviceSetupRow: Equatable, Sendable {
    /// Set up cmux… (every Mac, when the bundled cmux-tui has `device setup`).
    public var showsSetup: Bool
    /// Start cmux on NAME (an offline Mac, when the bundled cmux-tui has `device start`).
    public var showsStart: Bool
    public var run: MacScreenDeviceRun?

    public init(showsSetup: Bool = false, showsStart: Bool = false, run: MacScreenDeviceRun? = nil) {
        self.showsSetup = showsSetup
        self.showsStart = showsStart
        self.run = run
    }

    /// No button and no run (a phone, a cmux-tui without the verbs, before the verbs are read).
    public static let none = MacScreenDeviceSetupRow()

    /// The buttons a device shows. Only a Mac: a phone has no cmux to set up. A verb the bundled
    /// cmux-tui does not list (or `verbs` not read yet) shows no button; Start only while the Mac is
    /// offline, and while a Start runs (its row may come online before the run ends).
    public static func make(isMac: Bool, online: Bool, verbs: MacScreenDeviceVerbs?, run: MacScreenDeviceRun?) -> MacScreenDeviceSetupRow {
        guard isMac else { return .none }
        let verbs = verbs ?? MacScreenDeviceVerbs([])
        let starting = run?.verb == .start && run?.isRunning == true
        return MacScreenDeviceSetupRow(showsSetup: verbs.has(.setup),
                                       showsStart: verbs.has(.start) && (!online || starting),
                                       run: run)
    }

    /// Whether a button of `verb` can be pressed now (no run of either verb in flight).
    public func canRun(_ verb: MacScreenDeviceVerb) -> Bool {
        run?.isRunning != true && (verb == .setup ? showsSetup : showsStart)
    }
}

/// The runs of Set up cmux and Start cmux, by hub device id, for every Screen Sharing page and card
/// of the app. The app hands it the bundled cmux-tui (``runner``); without one no button shows.
@MainActor @Observable
public final class MacScreenDeviceSetup {
    /// One `cmux-tui <arguments>` run's stdout lines; it ends with ``MacScreenDeviceRunStop`` on a
    /// non-zero exit, and cancelling the stream stops the process.
    public typealias Runner = @Sendable ([String]) -> AsyncThrowingStream<String, any Error>

    /// The bundled cmux-tui (the app sets it); nil: none, so no button shows.
    @ObservationIgnored public var runner: Runner?
    /// A run of `verb` on device `id` succeeded (the pages read the hub's devices again).
    @ObservationIgnored public var succeeded: @MainActor (_ id: String, _ verb: MacScreenDeviceVerb) -> Void = { _, _ in }
    /// The verbs the bundled cmux-tui runs; nil until read.
    public private(set) var verbs: MacScreenDeviceVerbs?
    /// Each device's last run, by hub device id, until dismissed.
    public private(set) var runs: [String: MacScreenDeviceRun] = [:]
    @ObservationIgnored private var verbsRead: Task<Void, Never>?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init(runner: Runner? = nil) {
        self.runner = runner
    }

    /// The runner of the app's bundled cmux-tui (`HostCLI.lines`, as Add Machine runs it): its
    /// non-zero exit reaches the run as ``MacScreenDeviceRunStop``.
    public nonisolated static func runner(_ cli: HostCLI) -> Runner {
        { arguments in
            let lines = cli.lines(arguments)
            return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1024)) { continuation in
                // task-owner: forwards one run's lines; the stream's end cancels it, which stops the process.
                let forward = Task {
                    do {
                        for try await line in lines { continuation.yield(line) }
                        continuation.finish()
                    } catch let stop as HostCLIStop {
                        continuation.finish(throwing: MacScreenDeviceRunStop(status: stop.status, message: stop.message))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in forward.cancel() }
            }
        }
    }

    /// What device `id` shows.
    public func row(id: String, isMac: Bool, online: Bool) -> MacScreenDeviceSetupRow {
        .make(isMac: isMac, online: online, verbs: runner == nil ? nil : verbs, run: runs[id])
    }

    /// Reads the bundled cmux-tui's verbs once (`device help`); a page or card calls it as it shows.
    public func readVerbsIfNeeded() {
        guard verbs == nil, verbsRead == nil, let runner else { return }
        // task-owner: one short `device help` run; ends with it.
        verbsRead = Task { [weak self] in
            var usage = ""
            do {
                for try await line in runner(["device", "help"]) { usage += line + "\n" }
            } catch {}
            guard let self else { return }
            verbs = MacScreenDeviceVerbs.parse(usage: usage)
            verbsRead = nil
        }
    }

    /// Runs `verb` on device `id` (named `name` to the CLI), on a person's press. Ignored while a run
    /// of that device is in flight.
    public func run(_ verb: MacScreenDeviceVerb, id: String, name: String) {
        guard let runner, runs[id]?.isRunning != true else { return }
        runs[id] = MacScreenDeviceRun(verb: verb)
        let lines = runner(verb.arguments(device: name))
        // task-owner: one device run; ends with the process, or with dismiss.
        tasks[id] = Task { [weak self] in
            var stop: MacScreenDeviceRunStop?
            do {
                for try await text in lines {
                    guard let line = MacScreenDeviceLine.parse(text) else { continue }
                    self?.runs[id]?.take(line)
                }
            } catch let failure as MacScreenDeviceRunStop {
                stop = failure
            } catch is CancellationError {
                return
            } catch {
                stop = MacScreenDeviceRunStop(status: nil, message: error.localizedDescription)
            }
            guard let self, !Task.isCancelled, runs[id]?.isRunning == true else { return }
            runs[id]?.end(stop)
            tasks[id] = nil
            if runs[id]?.phase == .needsNewerCmux { verbs?.known.remove(verb) }
            if runs[id]?.phase == .succeeded { succeeded(id, verb) }
        }
    }

    /// Hides device `id`'s finished run (Done), or stops one in flight.
    public func dismiss(id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        runs[id] = nil
    }
}
