public import Foundation

/// `cloud new-machine --bootstrap-script FILE` (and `--repo`): the script, its runner and the repo
/// step go to the new machine over the Cloud file API, and one short exec starts the runner
/// detached. The scripts, the commands, the order of the writes and execs, and how each answer and
/// the run's end are read are cmux-tui's `cmux-cloud-start-core` (`machine_bootstrap`, with their
/// tests), asked over the app FFI (`cloud_bootstrap_*`, `cloud_machine_step_outcome`); this type
/// only makes the writes and execs its plan lists.
public struct CloudMachineBootstrap: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable, Codable { case plain, lane }

    public var kind: Kind
    public var contents: Data
    public var repo: CloudMachineRepo?

    public init(kind: Kind, contents: Data, repo: CloudMachineRepo? = nil) {
        self.kind = kind
        self.contents = contents
        self.repo = repo
    }

    /// The paths, limits and fixed texts Rust names (`cloud_bootstrap_facts`).
    /// When the FFI does not answer, the paths stay the machine's fixed folders (the secrets
    /// receiver and its ticket live in the config folder, never at `/`), and the limits are zero:
    /// every file is then too large, never read unchecked. `CloudNewMachineTests` checks these
    /// paths against Rust's answer.
    nonisolated struct Facts: Decodable, Equatable, Sendable {
        var directory = "/home/cmux/.cmux/bootstrap", logPath = "/home/cmux/.cmux/bootstrap/bootstrap.log"
        var statusPath = "/home/cmux/.cmux/bootstrap/status.json", noScript = "", waitCommand = ""
        var configDirectory = "/home/cmux/.cmux/machine-config"
        var configStatusPath = "/home/cmux/.cmux/machine-config/status.json"
        var configLogPath = "/home/cmux/.cmux/machine-config/setup.log"
        var maxBytes = 0, configMaxBytes = 0
    }

    nonisolated static let facts = CloudStartCore().call("cloud_bootstrap_facts", [String: String](), as: Facts.self) ?? Facts()

    /// The script of a machine that only clones a repository.
    public nonisolated static var noScript: Data { Data(facts.noScript.utf8) }
    public nonisolated static var directory: String { facts.directory }
    public nonisolated static var logPath: String { facts.logPath }
    public nonisolated static var statusPath: String { facts.statusPath }
    /// The longest script the app uploads.
    public nonisolated static var maxBytes: Int { facts.maxBytes }
    /// One read of the run's end (``waitForRun(on:bound:)``).
    public nonisolated static var waitCommand: String { facts.waitCommand }

    /// The calls a bootstrap makes, over ``CloudAPIClient`` in the app and fakes in tests.
    public struct Machine: Sendable {
        var write: @Sendable (_ path: String, _ data: Data, _ mode: Int) async throws -> Void
        var exec: @Sendable (_ command: String) async throws -> CloudExecResult

        public init(write: @escaping @Sendable (String, Data, Int) async throws -> Void,
                    exec: @escaping @Sendable (String) async throws -> CloudExecResult) {
            self.write = write
            self.exec = exec
        }

        public init(api: CloudAPIClient, machineID: String) {
            self.init(write: { try await api.writeFile(machineID, path: $0, data: $1, mode: $2) },
                      exec: { try await api.exec(machineID, command: $0, timeoutMs: 20_000) })
        }
    }

    /// How a start went: `started`, `running` (another start's run is under way; this one's files are
    /// dropped), `skipped` (this script and repo step already finished here) or `failed` with its `reason`.
    public struct Outcome: Equatable, Sendable, Decodable {
        public var status: String
        public var reason: String?

        public init(status: String, reason: String? = nil) {
            self.status = status
            self.reason = reason
        }

        static let unanswered = Outcome(status: "failed", reason: "the app's bootstrap rules did not answer")
    }

    /// Uploads the script with its environment, the runner and the repo step into a folder of this
    /// start's own, then starts: no upload ever changes the files a running runner runs.
    public func start(name: String?, on machine: Machine, startID: String = UUID().uuidString.lowercased()) async -> Outcome {
        struct Request: Encodable { var kind: Kind, name: String?, repo: CloudMachineRepo?, startId: String }
        guard let plan = CloudStartCore().call("cloud_bootstrap_start_plan", Request(kind: kind, name: name, repo: repo, startId: startID),
                                               as: Plan.self) else { return .unanswered }
        return await plan.run(on: machine, script: contents, config: nil)
    }

    /// The writes and execs of one start or apply, in order (`cloud_bootstrap_start_plan`, `cloud_machine_config_plan`).
    struct Plan: Decodable, Sendable {
        enum Step: Decodable, Sendable {
            case write(path: String, mode: Int, text: String?, payload: String?)
            case exec(command: String, said: [String])

            enum CodingKeys: String, CodingKey { case kind, path, mode, text, payload, command, said }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if try c.decode(String.self, forKey: .kind) == "exec" {
                    self = .exec(command: try c.decode(String.self, forKey: .command), said: try c.decode([String].self, forKey: .said))
                } else {
                    self = .write(path: try c.decode(String.self, forKey: .path), mode: try c.decode(Int.self, forKey: .mode),
                                  text: try c.decodeIfPresent(String.self, forKey: .text), payload: try c.decodeIfPresent(String.self, forKey: .payload))
                }
            }
        }

        var steps: [Step]

        /// Makes each step; after each exec Rust says go on or the outcome (`cloud_machine_step_outcome`).
        func run(on machine: Machine, script: Data?, config: Data?) async -> Outcome {
            do {
                for step in steps {
                    switch step {
                    case let .write(path, mode, text, payload):
                        let data = text.map { Data($0.utf8) } ?? (payload == "config" ? config : script) ?? Data()
                        try await machine.write(path, data, mode)
                    case let .exec(command, said):
                        let ran = try await machine.exec(command)
                        struct Request: Encodable { var answer: ExecAnswer, said: [String] }
                        struct Reply: Decodable { var outcome: Outcome? }
                        guard let reply = CloudStartCore().call("cloud_machine_step_outcome", Request(answer: ExecAnswer(ran), said: said),
                                                                as: Reply.self) else { return .unanswered }
                        if let outcome = reply.outcome { return outcome }
                    }
                }
                return .unanswered
            } catch {
                return Outcome(status: "failed", reason: String(describing: error))
            }
        }
    }

    /// An exec's answer as Rust reads it.
    struct ExecAnswer: Encodable, Sendable {
        var exitCode: Int, stdout: String, stderr: String
        init(_ ran: CloudExecResult) {
            exitCode = ran.exitCode
            stdout = ran.stdout
            stderr = ran.stderr
        }
    }
}

/// How a started bootstrap ended, for a caller that needs its clone (the New Cloud Workspace wizard's
/// "From repository" opens the project at ``Completion/finished(repoPath:)``). Each read of the run's
/// end blocks on the runner's `alive` lock on the machine; Rust reads its answer (`cloud_bootstrap_wait_next`).
extension CloudMachineBootstrap {
    /// The run's end, in words a person reads (the app's `waitForCompletion(on:)` localizes ``Run``).
    public enum Completion: Equatable, Sendable {
        /// The script, and the clone when one was asked, finished. `repoPath` is the clone's absolute
        /// path on the machine (`/home/cmux/work/NAME`); nil without a repo.
        case finished(repoPath: String?)
        case failed(reason: String)
    }

    /// The run's end as the machine's status says it, before it becomes words.
    public enum Run: Equatable, Sendable, Decodable {
        case finished(repoPath: String?)
        /// The repo step found no GitHub access to `repo` (`OWNER/NAME`) on the machine.
        case needsGitHub(repo: String)
        /// The clone or update of `repo` failed (another repository in its folder, a missing ref…).
        case repoFailed(repo: String)
        case scriptFailed(exitCode: Int)
        /// The start's runner never took over (it came a minute late, or not at all).
        case runnerNeverCame
        /// The runner ended without writing its end (killed, or the machine restarted).
        case stopped
        /// The wait's bound passed (or the wait was cancelled) while the runner still ran.
        case stillRunning
        /// The machine did not answer three reads in a row; the last error's text.
        case unreachable(String)

        enum CodingKeys: String, CodingKey { case run, repoPath, repo, exitCode, error }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .run) {
            case "finished": self = .finished(repoPath: try c.decodeIfPresent(String.self, forKey: .repoPath))
            case "needsGitHub": self = .needsGitHub(repo: try c.decode(String.self, forKey: .repo))
            case "repoFailed": self = .repoFailed(repo: try c.decode(String.self, forKey: .repo))
            case "scriptFailed": self = .scriptFailed(exitCode: try c.decode(Int.self, forKey: .exitCode))
            case "runnerNeverCame": self = .runnerNeverCame
            case "stopped": self = .stopped
            case "stillRunning": self = .stillRunning
            default: self = .unreachable(try c.decodeIfPresent(String.self, forKey: .error) ?? "")
            }
        }
    }

    /// Waits for the run a start began (`started`, `running` or `skipped`) to end: one ``waitCommand``
    /// after another, each blocked on the runner's lock, until the run ended or `bound` passes. Three
    /// failed reads in a row end it as ``Run/unreachable(_:)``; a cancelled wait ends as
    /// ``Run/stillRunning``. Every read that says read again takes at least a second, so one read a
    /// second of `bound` is enough reads.
    public func waitForRun(on machine: Machine, bound: Duration = .seconds(3 * 3600)) async -> Run {
        struct Read: Encodable { var answer: ExecAnswer?, error: String?, failures: Int, repo: CloudMachineRepo? }
        struct Next: Decodable { var ended: Run?, failures: Int, unreachable: Run? }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: bound)
        var failures = 0
        for _ in 0...max(0, bound.components.seconds) {
            guard !Task.isCancelled else { break }
            var read = Read(answer: nil, error: nil, failures: failures, repo: repo)
            do { read.answer = ExecAnswer(try await machine.exec(Self.waitCommand)) } catch { read.error = String(describing: error) }
            guard let next = CloudStartCore().call("cloud_bootstrap_wait_next", read, as: Next.self) else {
                return .unreachable(Outcome.unanswered.reason ?? "")
            }
            if let ended = next.ended { return ended }
            failures = next.failures
            // Cancelled during the read: the run's end is unknown, never the machine's fault.
            guard !Task.isCancelled else { break }
            if let unreachable = next.unreachable { return unreachable }
            if clock.now >= deadline { break }
        }
        return .stillRunning
    }
}

/// `.cmux/machine.toml`: one declared source per machine for its env, its secret names and its setup.
/// The machine parses and applies it (the applier, its start and the staging rules are
/// `cmux-cloud-start-core`'s `machine_config`, `cloud_machine_config_plan`); this type uploads them.
public struct CloudMachineConfig: Equatable, Sendable {
    /// The file to upload; nil applies what the machine has.
    public var contents: Data?

    public init(contents: Data?) {
        self.contents = contents
    }

    public nonisolated static var directory: String { CloudMachineBootstrap.facts.configDirectory }
    public nonisolated static var statusPath: String { CloudMachineBootstrap.facts.configStatusPath }
    public nonisolated static var logPath: String { CloudMachineBootstrap.facts.configLogPath }
    /// The largest file the applier takes.
    public nonisolated static var maxBytes: Int { CloudMachineBootstrap.facts.configMaxBytes }

    /// Uploads the applier and stages this request, then starts the applier with one short exec.
    public func apply(on machine: CloudMachineBootstrap.Machine, now: Date = Date()) async -> CloudMachineBootstrap.Outcome {
        struct Request: Encodable { var uploaded: Bool, nowMs: Int64, nonce: String }
        let request = Request(uploaded: contents != nil, nowMs: Int64(now.timeIntervalSince1970 * 1000), nonce: UUID().uuidString)
        guard let plan = CloudStartCore().call("cloud_machine_config_plan", request, as: CloudMachineBootstrap.Plan.self) else {
            return .unanswered
        }
        return await plan.run(on: machine, script: nil, config: contents)
    }
}
