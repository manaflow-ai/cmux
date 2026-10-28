import Foundation
public import Observation

/// One `cmux-tui acp host` run the Add Machine card starts (plans/cmux-next/add-machine-DESIGN.md).
public nonisolated enum HostCommand: Equatable, Sendable {
    /// `host enroll HOST --name N --json`: every step, fixing what it can.
    case enroll(host: String, name: String)
    /// `host doctor NAME|HOST [--fix] --json`: the checks alone, or `--fix` for the failed ones.
    case doctor(host: String, fix: Bool)

    /// The arguments after the `cmux-tui` binary.
    public var arguments: [String] {
        switch self {
        case let .enroll(host, name): ["acp", "host", "enroll", host, "--name", name, "--json"]
        case let .doctor(host, fix): ["acp", "host", "doctor", host] + (fix ? ["--fix"] : []) + ["--json"]
        }
    }
}

/// What a card button does. One path for the click and the key.
public nonisolated enum AddMachineAction: Equatable, Sendable {
    /// Start the add (enroll) for the field's host.
    case add
    /// Run the same add again after a failure.
    case tryAgain
    /// `doctor --fix` for the checked machine.
    case fix
    /// Open a workspace on the added machine and close.
    case openWorkspace
    /// Copy the checklist as text (a bug report, a message to whoever runs the host).
    case copyDetails
    /// Close after a finished run.
    case done
    /// Stop a run, drop the draft and close.
    case cancel
}

/// One button of the card's footer: its action, the key that presses it (Return, Escape, or none for
/// Copy Details) and whether it is on.
public nonisolated struct AddMachineButton: Equatable, Sendable {
    public nonisolated enum Key: Equatable, Sendable {
        case `return`
        case escape
    }

    public var action: AddMachineAction
    public var key: Key?
    public var enabled: Bool

    public init(action: AddMachineAction, key: Key?, enabled: Bool = true) {
        self.action = action
        self.key = key
        self.enabled = enabled
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

/// What the app does around the CLI, so the card's flow runs the same in tests with fixture lines.
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

/// The Add Machine card's state (plans/cmux-next/add-machine-DESIGN.md): pick a host, run enroll
/// (or doctor for Check Machine) with its checklist filling in live from the CLI's lines, then
/// ready or failed. The card, the palette, the CLI and a reopen read the same model; the click and
/// the key run ``perform(_:)``.
@Observable
public final class AddMachineModel {
    public nonisolated enum Mode: Equatable, Sendable {
        /// Add Machine: the field and the Tailscale list, then enroll.
        case add
        /// Check Machine: doctor for one SSH machine the app has, with Fix.
        case check(host: String, machineID: String)
    }

    public nonisolated enum Phase: Equatable, Sendable {
        case pick
        case running
        /// Every step healthy (warnings allowed).
        case ready(HostReport)
        /// A step failed, or the run stopped without a report (nil).
        case failed(HostReport?)
    }

    public private(set) var mode: Mode = .add
    public private(set) var phase: Phase = .pick
    /// The host field: `user@host` or a Tailscale name.
    public var destination = ""
    /// The Name field; empty means ``defaultName``.
    public var name = ""
    public private(set) var candidates: HostCandidates = .loading
    public private(set) var checklist = HostChecklist()
    /// The app installs its own cmux-tui build because enroll's install step failed (its row says so).
    public private(set) var installingAppBuild = false
    /// The app id of the machine once it is connected in the app.
    public private(set) var machineID: String?
    /// The host and name of the last run (the ready title, Copy Details).
    public private(set) var runHost = ""
    public private(set) var runName = ""
    /// The agent peer last picked from the list (already enrolled, not in the app yet): while the
    /// field still holds its destination, Add connects it and checks it instead of enrolling.
    public private(set) var pickedPeer: HostCandidate?

    @ObservationIgnored private let services: AddMachineServices
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var candidatesTask: Task<Void, Never>?

    public init(services: AddMachineServices) {
        self.services = services
    }

    // MARK: Opening

    /// Add Machine opens: a fresh card on the field (a run in flight keeps showing). A destination
    /// (the CLI, MCP, a script) only fills the fields: the add starts when the person presses Add,
    /// so nothing outside the app can enroll a machine without a click (trust policy, the
    /// conservative default until it is decided).
    public func begin(destination: String? = nil, name: String? = nil) {
        if phase == .running, mode == .add { return }
        cancelRun()
        mode = .add
        phase = .pick
        checklist = HostChecklist()
        machineID = nil
        self.destination = destination ?? ""
        self.name = name ?? ""
        pickedPeer = nil
        loadCandidates()
    }

    /// Check Machine opens on `host` (an SSH machine the app has) and runs doctor.
    public func beginCheck(host: String, machineID: String) {
        let check = Mode.check(host: host, machineID: machineID)
        if phase == .running, mode == check { return }
        cancelRun()
        candidatesTask?.cancel()
        mode = check
        self.machineID = machineID
        runHost = host
        runName = services.parse(host)?.shortName ?? host
        doctor(fix: false)
    }

    /// A candidate row was clicked: its name goes in the field. Nothing runs until Add is pressed,
    /// an agent peer included (the person's click is the trust step).
    public func pick(_ candidate: HostCandidate) {
        guard candidate.isPickable, phase == .pick else { return }
        destination = candidate.destination
        pickedPeer = candidate.alreadyPeer ? candidate : nil
    }

    /// The picked agent peer and its destination while the field still holds it.
    private var peerTarget: (candidate: HostCandidate, destination: HostDestination)? {
        guard let pickedPeer, destination == pickedPeer.destination, let parsed = services.parse(destination) else { return nil }
        return (pickedPeer, parsed)
    }

    // MARK: State

    /// The machine's name when the Name field is empty: the short host.
    public var defaultName: String {
        if let peerTarget { return Self.trimmed(peerTarget.candidate.peer ?? "") ?? peerTarget.destination.shortName }
        return services.parse(destination)?.shortName ?? ""
    }

    /// Whether the field holds a destination ssh can take.
    public var canAdd: Bool { peerTarget != nil || services.parse(destination) != nil }

    /// The footer: Escape (or no key) first, Return last.
    public var buttons: [AddMachineButton] {
        switch (phase, mode) {
        case (.pick, _):
            [AddMachineButton(action: .cancel, key: .escape), AddMachineButton(action: .add, key: .return, enabled: canAdd)]
        case (.running, .add):
            [AddMachineButton(action: .cancel, key: .escape), AddMachineButton(action: .add, key: .return, enabled: false)]
        case (.running, .check):
            [AddMachineButton(action: .cancel, key: .escape), AddMachineButton(action: .fix, key: .return, enabled: false)]
        case (.ready, .add):
            [AddMachineButton(action: .done, key: .escape), AddMachineButton(action: .openWorkspace, key: .return, enabled: machineID != nil)]
        case (.ready, .check):
            [AddMachineButton(action: .done, key: .return)]
        case (.failed, .add):
            [AddMachineButton(action: .copyDetails, key: nil), AddMachineButton(action: .tryAgain, key: .return)]
        case (.failed, .check):
            [AddMachineButton(action: .copyDetails, key: nil), AddMachineButton(action: .fix, key: .return)]
        }
    }

    /// Runs a card button (its click or its key). Returns true when the card should close.
    @discardableResult
    public func perform(_ action: AddMachineAction) -> Bool {
        switch action {
        case .add, .tryAgain:
            add()
            return false
        case .fix:
            doctor(fix: true)
            return false
        case .openWorkspace:
            if let machineID { services.openWorkspace(machineID) }
            return true
        case .copyDetails:
            services.copy(details)
            return false
        case .done:
            return true
        case .cancel:
            cancelRun()
            if phase == .running { phase = .pick }
            return true
        }
    }

    /// Waits for the run in flight; nil when it ended ready, else why not (the CLI's answer).
    public func finished() async -> String? {
        // A Fix or Try Again replaces the task while this waits: wait for each run in turn until the
        // one in place has finished (or a Cancel left none).
        var waited: Task<Void, Never>?
        while let current = task, current != waited {
            await current.value
            waited = current
        }
        switch phase {
        case .ready: return nil
        case .failed, .pick, .running: return checklist.failing.map { "\($0.step.rawValue): \($0.detail)" } ?? details
        }
    }

    /// The checklist as plain text: host, name and one line per step with its fix.
    public var details: String {
        var lines = ["host: \(runHost)", "name: \(runName)"]
        for row in checklist.rows {
            let state = switch row.status {
            case .pending: "pending"
            case .running: "running"
            case let .done(state): state.rawValue
            }
            var line = "\(row.step.rawValue): \(state)"
            if !row.detail.isEmpty { line += " - \(row.detail)" }
            if let fix = row.fix { line += " (fix: \(fix))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Runs

    private func add() {
        if let peerTarget {
            addPeer(peerTarget.candidate, host: peerTarget.destination.host, name: Self.trimmed(name) ?? defaultName)
            return
        }
        guard let parsed = services.parse(destination) else { return }
        let host = parsed.host
        let name = Self.trimmed(name) ?? parsed.shortName
        cancelRun()
        candidatesTask?.cancel()
        runHost = host
        runName = name
        phase = .running
        machineID = nil
        let services = services
        task = Task { [weak self] in
            guard let self else { return }
            var report = await stream(.enroll(host: host, name: name))
            if let first = report, Self.needsAppInstall(first) {
                // The app's own install path (remote.connect, remote.install) puts the right-arch
                // build on the host; enroll then runs again from the top.
                installingAppBuild = true
                checklist.run(.install)
                let installed = await services.install(host, name)
                installingAppBuild = false
                guard !Task.isCancelled else { return }
                switch installed {
                case let .installed(id):
                    machineID = id
                    report = await stream(.enroll(host: host, name: name))
                case let .failed(message):
                    checklist.stop(message)
                    phase = .failed(first)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard let report else { phase = .failed(nil); return }
            if report.ok, machineID == nil { machineID = services.connect(host, name) }
            if let machineID { services.record(machineID, report) }
            phase = report.ok ? .ready(report) : .failed(report)
        }
    }

    /// An agent peer the app does not have: enroll already ran for it, so the app connects it under
    /// `name` and runs doctor (by its peer name) for the checklist.
    private func addPeer(_ candidate: HostCandidate, host: String, name: String) {
        cancelRun()
        candidatesTask?.cancel()
        runHost = host
        runName = name
        phase = .running
        machineID = nil
        let services = services
        task = Task { [weak self] in
            guard let self else { return }
            guard let id = services.connect(host, name) else {
                checklist.start()
                checklist.stop(AddMachineStrings.peerConnectFailed)
                phase = .failed(nil)
                return
            }
            machineID = id
            let report = await stream(.doctor(host: Self.trimmed(candidate.peer ?? "") ?? host, fix: false))
            guard !Task.isCancelled else { return }
            guard let report else { phase = .failed(nil); return }
            services.record(id, report)
            phase = report.ok ? .ready(report) : .failed(report)
        }
    }

    private func doctor(fix: Bool) {
        guard case let .check(host, machineID) = mode else { return }
        cancelRun()
        phase = .running
        let services = services
        task = Task { [weak self] in
            guard let self else { return }
            let report = await stream(.doctor(host: host, fix: fix))
            guard !Task.isCancelled else { return }
            guard let report else { phase = .failed(nil); return }
            services.record(machineID, report)
            phase = report.ok ? .ready(report) : .failed(report)
        }
    }

    /// Runs one command into the checklist; its report, or nil when it ended without one.
    private func stream(_ command: HostCommand) async -> HostReport? {
        checklist.start()
        var report: HostReport?
        do {
            for try await line in services.run(command) {
                switch HostLine.parse(line) {
                case let .step(step)?: checklist.apply(step)
                case let .report(value)?: report = value; checklist.finish(value)
                case nil: continue
                }
            }
        } catch {
            // A report that came first is the answer: a failed run exits non-zero after it.
            if report == nil, !Task.isCancelled { checklist.stop(error.localizedDescription) }
        }
        if report == nil, !Task.isCancelled, checklist.failing == nil { checklist.stop("") }
        return report
    }

    private func loadCandidates() {
        candidatesTask?.cancel()
        candidates = .loading
        let services = services
        candidatesTask = Task { [weak self] in
            // The plain list first (one local tailscale call), then the ssh probe of the user's own
            // machines; a probe that fails or times out leaves the unprobed list showing.
            let list = await services.candidates(false)
            guard !Task.isCancelled, let self else { return }
            candidates = list.map { .loaded($0) } ?? .unavailable
            guard list != nil else { return }
            let probed = await services.candidates(true)
            guard !Task.isCancelled, let probed else { return }
            candidates = .loaded(probed)
        }
    }

    private func cancelRun() {
        task?.cancel()
        task = nil
        installingAppBuild = false
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
