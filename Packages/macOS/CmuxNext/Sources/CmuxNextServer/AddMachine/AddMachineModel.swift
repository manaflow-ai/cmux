import CmuxNextRemote
import Foundation

/// One `cmux-tui acp host` run the Add Machine card starts (plans/cmux-next/add-machine-DESIGN.md).
public nonisolated enum HostCommand: Equatable, Sendable {
    /// `host enroll HOST --name N --harness local --reverse --json`: every step, fixing what it can,
    /// with this Mac's agent profiles copied and the host peered back, so setup leaves no skips.
    /// The Add click opts into recording a new SSH host key; changed keys still fail.
    case enroll(host: String, name: String)
    /// `host doctor NAME|HOST [--fix] --json`: the checks alone, or `--fix` for the failed ones plus
    /// the setup enroll does (profiles, peer-back).
    case doctor(host: String, fix: Bool)
    /// `machine doctor ID --json`: the minting end's checks of a machine that joined with a one-line
    /// token or a pair code. It reads the cmux access token on stdin (``needsAccount``).
    case joinedDoctor(id: String)

    /// The arguments after the `cmux-tui` binary.
    public var arguments: [String] {
        switch self {
        case let .enroll(host, name): ["acp", "host", "enroll", host, "--name", name, "--accept-new-host-key"] + Self.setup + ["--json"]
        case let .doctor(host, fix): ["acp", "host", "doctor", host] + (fix ? ["--fix"] + Self.setup : []) + ["--json"]
        case let .joinedDoctor(id): ["machine", "doctor", id, "--json", "--cloud-token-stdin"]
        }
    }

    /// What setup copies and adds besides the machine itself: every agent profile this Mac has
    /// (`--harness local`) and this Mac as the host's peer (`--reverse`, a warning when it fails).
    private static let setup = ["--harness", "local", "--reverse"]

    /// The run reads the signed-in account's cmux access token as one line on its stdin.
    public var needsAccount: Bool {
        if case .joinedDoctor = self { return true }
        return false
    }
}

/// A host the field holds, as ssh takes it.
public nonisolated struct HostDestination: Equatable, Sendable {
    /// The canonical `[user@]host` the CLI gets (never a port: enroll refuses one).
    public var host: String
    /// The sidebar's short name (`huge-blue` for `leo@huge-blue.tail1234.ts.net`): the default Name.
    public var shortName: String

    public init(host: String, shortName: String) {
        self.host = host
        self.shortName = shortName
    }
}

/// What the app does around the CLI, so the runs go the same in tests with fixture lines.
public struct AddMachineServices {
    /// What an install from the app did: the machine it connected (its app id), or why it failed.
    public nonisolated enum Installed: Equatable, Sendable {
        case installed(machineID: String)
        case failed(String)

        /// Runs an install that returns the machine's id; a thrown error fails with its own words.
        public static func attempt(_ install: () async throws -> String) async -> Installed {
            do {
                return .installed(machineID: try await install())
            } catch {
                return .failed((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }

    /// Reads the field (`SSHDestination`); nil when ssh cannot take it.
    public var parse: (String) -> HostDestination?
    /// The Tailscale peers (`host candidates --json`, with `--probe` when `probe`), nil without
    /// Tailscale or when the run failed or timed out.
    public var candidates: (_ probe: Bool) async -> [HostCandidate]?
    /// The stdout lines of one CLI run; a run that ends without its report throws why.
    public var run: (HostCommand) -> AsyncThrowingStream<String, any Error>
    /// `remote.connect`'s install path: connects `host` in the app under `name` and installs this app's
    /// cmux-tui on it.
    public var install: (_ host: String, _ name: String) async -> Installed
    /// Connects `host` in the app under `name` once it is added: the machine's id, nil when it could not.
    public var connect: (_ host: String, _ name: String) -> String?
    /// The last enroll or doctor report of a machine (the Machines section's status).
    public var record: (_ machineID: String, _ report: HostReport) -> Void
    public var openWorkspace: (_ machineID: String) -> Void
    public var copy: (String) -> Void

    public init(parse: @escaping (String) -> HostDestination?, candidates: @escaping (Bool) async -> [HostCandidate]?,
                run: @escaping (HostCommand) -> AsyncThrowingStream<String, any Error>,
                install: @escaping (String, String) async -> Installed, connect: @escaping (String, String) -> String?,
                record: @escaping (String, HostReport) -> Void, openWorkspace: @escaping (String) -> Void,
                copy: @escaping (String) -> Void) {
        self.parse = parse
        self.candidates = candidates
        self.run = run
        self.install = install
        self.connect = connect
        self.record = record
        self.openWorkspace = openWorkspace
        self.copy = copy
    }
}

extension AddMachineServices {
    /// The field read as ssh takes it, for enroll and the app's connect alike. No port: enroll's ssh
    /// destination is `[user@]host` (acpmux `checked_host`); a port belongs in ~/.ssh/config, and an
    /// agent peer's URL port is its daemon's, not ssh's. An IPv6 host keeps its brackets
    /// (`leo@[fd7a::2]`) so the text parses back to the same host instead of a port.
    public static func hostDestination(_ text: String) -> HostDestination? {
        guard let parsed = try? SSHDestination(parsing: text), parsed.port == nil else { return nil }
        let host = parsed.host.contains(":") ? "[\(parsed.host)]" : parsed.host
        return HostDestination(host: (parsed.user.map { "\($0)@" } ?? "") + host, shortName: parsed.displayName)
    }
}

/// The runs behind the Add Machine card (plans/cmux-next/add-machine-DESIGN.md): what opened the card
/// and the run in flight, kept here so a run survives the card closing and a reopen, the CLI and Add
/// Device read the same one. Each run is the system work only (the CLI, the app's install fallback,
/// connect, the health record); it writes what happened as ``Event``s, and the card (the server-cards
/// page, `#/add-machine`) folds them into its checklist, its layout and its buttons.
@MainActor
public final class AddMachineRuns {
    public nonisolated enum Mode: Equatable, Sendable {
        /// Add Machine: the field and the Tailscale list, then enroll.
        case add
        /// Check Machine: doctor for one SSH machine the app has, with Fix.
        case check(host: String, machineID: String)
        /// Check for a machine that joined with a one-line token (``HostCommand/joinedDoctor(id:)``).
        /// No Fix: the minting end repairs nothing on another machine. `rowID`: the Machines row the
        /// result is recorded under.
        case checkJoined(id: String, name: String, rowID: String)
    }

    /// What opened the card; `seq` moves on every open so the card resets its fields once per open.
    public nonisolated struct Request: Equatable, Sendable {
        public var seq: Int
        public var mode: Mode
        public var destination: String?
        public var name: String?
    }

    /// One thing a run did, in order.
    public nonisolated enum Event: Equatable, Sendable {
        /// A run starts: a joined machine's check (`joined`) lists only the steps its run sends.
        case start(joined: Bool)
        /// One stdout line of the CLI.
        case line(String)
        /// The app installs its own cmux-tui build, and that ended.
        case install
        case installEnd
        /// The run stopped without a report: why (the CLI's or the app's words, or empty).
        case stop(String)
    }

    public nonisolated enum Outcome: String, Equatable, Sendable {
        case running, ready, failed
    }

    public nonisolated struct Run: Equatable, Sendable {
        public var id: Int
        public var host: String
        public var name: String
        /// What Add was asked for (the field's text and a picked agent peer), so Try Again sends
        /// this run again whatever the card's fields show now.
        public var destination: String?
        public var peer: String?
        public var events: [Event] = []
        public var outcome: Outcome = .running
        public var machineID: String?
        /// The report the run ended with (nil when it stopped without one).
        public var report: HostReport?
        /// Why it stopped without a report (``finished()``'s answer).
        public var stopped: String?
    }

    public private(set) var request = Request(seq: 0, mode: .add) {
        didSet { if request != oldValue { changed() } }
    }
    public private(set) var run: Run? {
        didSet { if run != oldValue { changed() } }
    }
    /// After each change of ``request`` or ``run`` (the card's provider tells the page).
    public var changed: @MainActor () -> Void = {}

    private let services: AddMachineServices
    private var task: Task<Void, Never>?
    private var nextRun = 0

    public init(services: AddMachineServices) {
        self.services = services
    }

    // MARK: Opening

    /// Add Machine opens: a fresh card on the field (a run of Add in flight keeps showing). A
    /// destination (the CLI, MCP, a script) only fills the fields: the add starts when the person
    /// presses Add, so nothing outside the app can enroll a machine without a click (trust policy, the
    /// conservative default until it is decided).
    public func begin(destination: String? = nil, name: String? = nil) {
        if run?.outcome == .running, request.mode == .add { return }
        cancelRun()
        run = nil
        request = Request(seq: request.seq + 1, mode: .add, destination: destination, name: name)
    }

    /// Check Machine opens on `host` (an SSH machine the app has) and runs doctor.
    public func beginCheck(host: String, machineID: String) {
        let mode = Mode.check(host: host, machineID: machineID)
        if run?.outcome == .running, request.mode == mode { return }
        cancelRun()
        request = Request(seq: request.seq + 1, mode: mode)
        doctor(fix: false)
    }

    /// Check opens on a joined machine (`machine doctor ID`); its result is recorded under
    /// ``JoinedMachine/healthID(_:)``.
    public func beginJoinedCheck(id: String, name: String, rowID: String? = nil) {
        let mode = Mode.checkJoined(id: id, name: name, rowID: rowID ?? JoinedMachine.healthID(id))
        if run?.outcome == .running, request.mode == mode { return }
        cancelRun()
        request = Request(seq: request.seq + 1, mode: mode)
        doctor(fix: false)
    }

    // MARK: The card's buttons

    /// Add or Try Again for `destination` under `name` (empty: its short name). With `peer`, the
    /// agent peer picked from the list (already enrolled): the app connects it and runs doctor --fix
    /// by its peer name instead of enrolling. The card asks this only from the person's own click or key.
    public func add(destination: String, name: String, peer: String? = nil) {
        guard request.mode == .add, let parsed = services.parse(destination) else { return }
        let name = Self.trimmed(name) ?? peer.flatMap(Self.trimmed) ?? parsed.shortName
        if let peer {
            return addPeer(peer: Self.trimmed(peer) ?? parsed.host, host: parsed.host, name: name,
                           asked: (destination, peer))
        }
        start(host: parsed.host, name: name, asked: (destination, nil)) { runs, services in
            var report = await runs.stream(.enroll(host: parsed.host, name: name))
            // Cancel can end the stream after it has parsed a report. Do not start the
            // app-install fallback from that retained report.
            guard !Task.isCancelled else { return }
            if let first = report, Self.needsAppInstall(first) {
                // The app's own install path (remote.connect, remote.install) puts the right-arch
                // build on the host; enroll then runs again from the top.
                runs.note(.install)
                let installed = await services.install(parsed.host, name)
                guard !Task.isCancelled else { return }
                runs.note(.installEnd)
                switch installed {
                case let .installed(id):
                    runs.run?.machineID = id
                    report = await runs.stream(.enroll(host: parsed.host, name: name))
                case let .failed(message):
                    runs.note(.stop(message))
                    runs.end(first, stopped: message)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if let report, report.ok, runs.run?.machineID == nil { runs.run?.machineID = services.connect(parsed.host, name) }
            if let report, let id = runs.run?.machineID { services.record(id, report) }
            runs.end(report)
        }
    }

    /// Fix: `doctor --fix` for the checked machine (Check Machine only). The card asks this only from
    /// the person's own click or key.
    public func fix() {
        guard case .check = request.mode else { return }
        doctor(fix: true)
    }

    /// Cancel and Change Host: the run stops and is forgotten; Add Machine shows its fields again.
    public func cancel() {
        cancelRun()
        run = nil
    }

    public func openWorkspace() {
        if let id = run?.machineID { services.openWorkspace(id) }
    }

    public func copy(_ text: String) { services.copy(text) }

    public func parse(_ text: String) -> HostDestination? { services.parse(text) }

    public func candidates(probe: Bool) async -> [HostCandidate]? { await services.candidates(probe) }

    /// Waits for the run in flight; nil when it ended ready, else why not (the failed step and its
    /// detail, or the CLI's words when it stopped without a report).
    public func finished() async -> String? {
        // A Fix or Try Again replaces the task while this waits: wait for each run in turn until the
        // one in place has finished (or a Cancel left none).
        var waited: Task<Void, Never>?
        while let current = task, current != waited {
            await current.value
            waited = current
        }
        guard let run else { return "cancelled" }
        switch run.outcome {
        case .ready: return nil
        case .running, .failed:
            if let step = run.report?.steps.first(where: { $0.state == .fail }) { return "\(step.step.rawValue): \(step.detail)" }
            return run.stopped.flatMap(Self.trimmed) ?? "host: \(run.host)\nname: \(run.name)"
        }
    }

    // MARK: Runs

    /// An agent peer the app does not have: enroll already ran for it, so the app connects it under
    /// `name` and runs doctor --fix (by its peer name) for the checklist and the rest of setup.
    private func addPeer(peer: String, host: String, name: String, asked: (destination: String, peer: String?)) {
        start(host: host, name: name, asked: asked) { runs, services in
            guard let id = services.connect(host, name) else {
                runs.note(.start(joined: false))
                runs.note(.stop(AddMachineStrings.peerConnectFailed))
                runs.end(nil, stopped: "\(HostStep.reach.rawValue): \(AddMachineStrings.peerConnectFailed)")
                return
            }
            runs.run?.machineID = id
            // `--fix`: the peer was enrolled by another run; finish its setup here (approvals,
            // profiles, peer-back) so the card ends ready, not with "run doctor --fix" warnings.
            let report = await runs.stream(.doctor(host: peer, fix: true))
            guard !Task.isCancelled else { return }
            if let report { services.record(id, report) }
            runs.end(report)
        }
    }

    private func doctor(fix: Bool) {
        let command: HostCommand, machineID: String, host: String, name: String
        switch request.mode {
        case let .check(checked, id):
            (command, machineID, host, name) = (.doctor(host: checked, fix: fix), id, checked, services.parse(checked)?.shortName ?? checked)
        case let .checkJoined(id, joinedName, rowID): (command, machineID, host, name) = (.joinedDoctor(id: id), rowID, id, joinedName)
        case .add: return
        }
        start(host: host, name: name) { runs, services in
            let report = await runs.stream(command)
            guard !Task.isCancelled else { return }
            if let report { services.record(machineID, report) }
            runs.end(report)
        }
        if case .check = request.mode { run?.machineID = machineID }
    }

    /// Replaces the run in flight with a new one running `body`.
    /// `asked`: what Add sent (nil for a check), kept on the run for Try Again.
    private func start(host: String, name: String, asked: (destination: String, peer: String?)? = nil,
                       _ body: @escaping @MainActor (AddMachineRuns, AddMachineServices) async -> Void) {
        cancelRun()
        nextRun += 1
        run = Run(id: nextRun, host: host, name: name, destination: asked?.destination, peer: asked?.peer)
        let services = services
        // task-owner: one run; Cancel, a new run or a reopen cancels it
        task = Task { [weak self] in
            guard let self else { return }
            await body(self, services)
        }
    }

    private func note(_ event: Event) {
        guard !Task.isCancelled else { return }
        run?.events.append(event)
    }

    private func end(_ report: HostReport?, stopped: String? = nil) {
        guard !Task.isCancelled, var run else { return }
        run.report = report
        run.stopped = stopped ?? run.stopped
        run.outcome = report?.ok == true ? .ready : .failed
        self.run = run
    }

    /// Runs one command, writing its lines; its report, or nil when it ended without one.
    private func stream(_ command: HostCommand) async -> HostReport? {
        // A joined machine's check runs other steps than enroll's: it shows the ones it sends.
        note(.start(joined: command.needsAccount))
        var report: HostReport?
        var stepFailed = false
        do {
            for try await line in services.run(command) {
                guard let parsed = HostLine.parse(line) else { continue }
                note(.line(line))
                switch parsed {
                case let .report(value): report = value
                case let .step(step): stepFailed = stepFailed || step.state == .fail
                }
            }
        } catch {
            // A report that came first is the answer: a failed run exits non-zero after it.
            if report == nil, !Task.isCancelled {
                note(.stop(error.localizedDescription))
                run?.stopped = error.localizedDescription
            }
            return report
        }
        // Ended without a report: the step running then fails, unless a step already failed.
        if report == nil, !Task.isCancelled, !stepFailed { note(.stop("")) }
        return report
    }

    private func cancelRun() {
        task?.cancel()
        task = nil
    }

    /// Enroll reached the host but this build cannot go on it: another OS or CPU, or a binary only
    /// the app has. The app installs its own build (the same as Install cmux-tui on Machine), then
    /// enroll runs again. Any other install failure (a probe that failed, a push that broke) is
    /// shown as it is.
    static func needsAppInstall(_ report: HostReport) -> Bool {
        report.steps.contains { step in
            step.step == .install && step.state == .fail
                && [HostStepResult.wrongPlatform, HostStepResult.notThisProgram,
                    HostStepResult.peerVersionSkew].contains(step.reason)
        } && !report.steps.contains { $0.step == .reach && $0.state == .fail }
    }

    private static func trimmed(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
