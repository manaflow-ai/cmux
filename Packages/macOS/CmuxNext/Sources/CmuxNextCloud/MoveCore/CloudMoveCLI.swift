public import CmuxNextDaemon
public import Foundation

/// The cmux-tui CLIs Move to Cloud, Bring Back Local and a chat start run (cmux-tui `link/sync_cli.rs`,
/// `link/agent_cli.rs`, `link/start_chat_cli.rs`). Rust names each call's arguments and reads its one
/// JSON answer line (cmux-cloud-start-core `moves::cli`, ops `cloud_move_cli_*`); this only runs the
/// process, with any credential on stdin, never in argv.
public nonisolated struct CloudMoveCLI: Sendable {
    /// One CLI's answer line, as Rust read it.
    public struct Answer: Sendable, Equatable, Codable {
        public var ok: Bool
        public var errorCode: String?
        public var error: String?
        /// `link agent move`: the chat's session on the machine, and the move's id.
        public var sessionID: String?
        public var transferID: String?
        /// `link sync pull`'s `sync_conflict`: the paths changed on both sides.
        public var conflicts: [String] = []
        /// `link agent move`'s `machine_outdated`: the daemon it is about, `source` or `target`.
        public var side: String?
        /// `link machine update`: whether the machine's cmux-tui changed, and the build it runs after it.
        public var updated = false
        public var build: String?
        /// `link machine update --if-older`: the machine runs a build not older than this app's.
        public var notOlder = false
        public var seedState: String?
        public var seedPhase: String?
        public var seedStartedAt: Double?
        public var seedFinishedAt: Double?
        /// `seed_refused`: the seed plan's code for why the machine can't clone the folder (`not_git`, ...).
        public var fallbackCode: String?
        /// `seed_refused` for `seed.needs_github`: the cmux GitHub App's install page for the repository.
        public var installURL: String?
        /// `seed_refused`: the bytes a copy of the folder would send; nil when cmux-tui could not read its size.
        public var copyBytes: Int64?
        /// `link seed fetch --find-root`: the machine's repository root the chat's folder is in.
        public var remoteRoot: String?
        /// A copy past its limits sent a first pass: the files it left on this Mac; nil for a whole copy.
        public var leftOnMac: Int64?
        /// `link start-chat plan`'s `cloud.size.locked`: the sizes and the upgrade the platform named (``CloudSizeLocked``).
        public var sizeLocked: JSONValue?
        /// `link start-chat plan`'s `seed_refused` for a machine smaller than the size asked (`machine.too_small`): its name.
        public var machineTitle: String?
        /// `link start-chat plan`'s refusal the same send may pass later (a busy machine, a rate limit, an
        /// outage; cmux-platform#1192), as Rust read it: the start card offers Retry. A rate limit's window in seconds.
        public var retryable = false
        public var retryAfterS: Int?

        public init(ok: Bool, errorCode: String? = nil, error: String? = nil, sessionID: String? = nil, transferID: String? = nil,
                    conflicts: [String] = [], side: String? = nil, updated: Bool = false, build: String? = nil, notOlder: Bool = false,
                    seedState: String? = nil, seedPhase: String? = nil, seedStartedAt: Double? = nil, seedFinishedAt: Double? = nil,
                    fallbackCode: String? = nil, installURL: String? = nil, copyBytes: Int64? = nil) {
            (self.ok, self.errorCode, self.error, self.sessionID, self.transferID) = (ok, errorCode, error, sessionID, transferID)
            (self.conflicts, self.side, self.updated, self.build, self.notOlder) = (conflicts, side, updated, build, notOlder)
            (self.seedState, self.seedPhase, self.seedStartedAt, self.seedFinishedAt) = (seedState, seedPhase, seedStartedAt, seedFinishedAt)
            (self.fallbackCode, self.installURL, self.copyBytes) = (fallbackCode, installURL, copyBytes)
        }

        /// `link machine update`: whether the machine's daemon may have restarted in the run that gave this
        /// answer (an update, a rollback, an end the CLI lost track of). An FFI that does not answer says it may have.
        public var mayHaveRestartedDaemon: Bool {
            struct Reply: Decodable { var restarted: Bool }
            return CloudMoveCore().call("restarted_daemon", self, as: Reply.self)?.restarted ?? true
        }
    }

    /// The `cmux` binary (the bundled cmux-tui).
    public let binary: URL
    /// How long one run may take; past it the run is killed and throws.
    public var timeout: Duration = .seconds(30 * 60)

    public init(binary: URL, timeout: Duration = .seconds(30 * 60)) {
        self.binary = binary
        self.timeout = timeout
    }

    /// The error code of an answer that isn't a JSON line (a crash, a kill).
    public static let badAnswer = "bad_answer"
    /// Longer than `link machine update`'s own wait for the machine (25 minutes) plus a first download.
    public static let machineUpdateTimeout: Duration = .seconds(45 * 60)

    /// The folder copy a move makes once the chat is frozen (`--sync`).
    public struct FrozenSync: Sendable, Equatable, Encodable {
        /// Pull from the machine (Bring Back Local) rather than seed it (Move to Cloud).
        public var pull: Bool
        public var socket: String
        public var local: String
        public var remote: String
        /// Machine to machine: the source machine's link socket, and `local` is its folder there;
        /// `seedLocal` is this Mac's folder a Move to Cloud seeded it from, whose record follows.
        public var fromSocket: String?, seedLocal: String?

        public init(pull: Bool, socket: String, local: String, remote: String, fromSocket: String? = nil, seedLocal: String? = nil) {
            (self.pull, self.socket, self.local, self.remote, self.fromSocket, self.seedLocal) = (pull, socket, local, remote, fromSocket, seedLocal)
        }
    }

    /// `cmux link start-chat plan`'s answer: the machine a `cloud.startChat` send takes (nil: make
    /// one named `newName`), pinned to the send, and the send's keys.
    public struct StartChatPlan: Sendable, Equatable, Decodable {
        public var machine: String?
        public var newName: String?
        public var createKey: String
        public var tabKey: String
        public var targetPane: String?
        public var createTeam: String?
        public var createSent: Bool = false
        public var environmentId: String?
        public var ensuredEnvironment: String?
        public var setup: CloudStartSetup?
        /// `machine` was made for this send by this plan (the platform's workspace machine it created now): a start
        /// that can't go on deletes it, as one the App made for it. A machine it found or a reservation it bound is never deleted.
        public var madeForSend: Bool = false
        /// The route the sent create took (the ledger's, from `create-sent --route`); nil: not sent, or sent on the
        /// relay before routes were kept. A retry takes it: the server keeps each key per caller.
        public var createRoute: CloudCreateRoute?
        /// The ledger keeps a sent create's route (this cmux-tui and this app's Rust core both know it). Without it a
        /// retry could not tell a direct send from a relayed one, so every create of the start is the relay's.
        public var keepsCreateRoute: Bool = false

        public init(machine: String? = nil, newName: String? = nil, createKey: String, tabKey: String,
                    environmentId: String? = nil, setup: CloudStartSetup? = nil, targetPane: String? = nil,
                    createTeam: String? = nil, createSent: Bool = false, madeForSend: Bool = false,
                    createRoute: CloudCreateRoute? = nil, keepsCreateRoute: Bool = false) {
            (self.machine, self.newName, self.createKey, self.tabKey, self.targetPane) = (machine, newName, createKey, tabKey, targetPane)
            (self.createTeam, self.createSent, self.environmentId, self.setup) = (createTeam, createSent, environmentId, setup)
            (self.madeForSend, self.createRoute, self.keepsCreateRoute) = (madeForSend, createRoute, keepsCreateRoute)
        }

        /// Whether the app's create for this start may go straight to the Cloud API as the person (`ownCreate`):
        /// only a start the person's own gesture in this app began (`personsOwnRun`), on a ledger that keeps the
        /// route, and not after the direct route refused this start once (`relayOnly`). The request then picks the
        /// route (``CloudMachineRequest/createRoute(personsOwnCreate:team:)``): a sent key keeps its first.
        public func ownCreate(personsOwnRun: Bool, relayOnly: Bool = false) -> Bool { keepsCreateRoute && personsOwnRun && !relayOnly }

        /// The route to record with a send on `route`: nil for a ledger that keeps none (it takes no `--route`).
        public func recorded(_ route: CloudCreateRoute) -> CloudCreateRoute? { keepsCreateRoute ? route : nil }

        enum CodingKeys: String, CodingKey { case machine, newName, createKey, tabKey, targetPane, createTeam, createSent, environmentId, ensuredEnvironment, setup, madeForSend, createRoute, keepsCreateRoute }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            machine = try container.decodeIfPresent(String.self, forKey: .machine)
            newName = try container.decodeIfPresent(String.self, forKey: .newName)
            createKey = try container.decode(String.self, forKey: .createKey)
            tabKey = try container.decode(String.self, forKey: .tabKey)
            targetPane = try container.decodeIfPresent(String.self, forKey: .targetPane)
            createTeam = try container.decodeIfPresent(String.self, forKey: .createTeam)
            createSent = try container.decodeIfPresent(Bool.self, forKey: .createSent) ?? false
            environmentId = try container.decodeIfPresent(String.self, forKey: .environmentId)
            ensuredEnvironment = try container.decodeIfPresent(String.self, forKey: .ensuredEnvironment)
            setup = try container.decodeIfPresent(CloudStartSetup.self, forKey: .setup)
            madeForSend = try container.decodeIfPresent(Bool.self, forKey: .madeForSend) ?? false
            // A route this app does not know is none: with the create sent, that is the relay (``CloudMachineRequest/createRoute(personsOwnCreate:team:)``).
            createRoute = try container.decodeIfPresent(String.self, forKey: .createRoute).flatMap(CloudCreateRoute.init(rawValue:))
            keepsCreateRoute = try container.decodeIfPresent(Bool.self, forKey: .keepsCreateRoute) ?? false
        }
    }

    /// `cmux link start-chat preflight`'s refusal: the folder a start may not copy (past the copy's limits, and not in
    /// git), asked before any machine or lease is made for it, with the git working copies right inside it to start in instead.
    public nonisolated struct StartChatPreflightRefusal: Sendable, Equatable, Error {
        public nonisolated struct Repo: Sendable, Equatable {
            public var name: String, path: String
            public init(name: String, path: String) { (self.name, self.path) = (name, path) }
        }
        /// The CLI's own sentence (logged; the page words the card from the fields below).
        public var message: String
        /// The folder as the person reads it (`~/Projects`), and at least what it holds.
        public var folder: String
        public var bytes: Double?, files: Double?
        public var repos: [Repo]
        /// More repositories were found than ``repos`` names.
        public var more: Bool

        public init(message: String, folder: String, bytes: Double? = nil, files: Double? = nil, repos: [Repo] = [], more: Bool = false) {
            (self.message, self.folder, self.bytes, self.files, self.repos, self.more) = (message, folder, bytes, files, repos, more)
        }

        /// The refusal an answer object names: only `copy.too_large`; nil for a pass or any other answer.
        public init?(answer: [String: Any]) {
            guard answer["ok"] as? Bool == false, answer["error_code"] as? String == Self.code else { return nil }
            let repos = (answer["repos"] as? [[String: Any]] ?? []).compactMap { repo -> Repo? in
                guard let name = repo["name"] as? String, let path = repo["path"] as? String, path.hasPrefix("/") else { return nil }
                return Repo(name: name, path: path)
            }
            self.init(message: answer["error"] as? String ?? Self.code, folder: answer["folder"] as? String ?? "",
                      bytes: (answer["bytes"] as? NSNumber)?.doubleValue, files: (answer["files"] as? NSNumber)?.doubleValue,
                      repos: repos, more: answer["repos_more"] as? Bool ?? false)
        }

        /// The copy's refusal code (cmux-tui `size_cap::CODE`).
        public static let code = "copy.too_large"
        /// The start card's code for it (webviews cloudStartProgress.ts).
        public static let replyCode = "cloud_folder_too_big"

        /// The start card's details: the folder, its size and the repositories to offer (CloudStartView).
        public var details: [String: Any] {
            var details: [String: Any] = ["folder": folder, "repos": repos.map { ["name": $0.name, "path": $0.path] }, "more": more]
            if let bytes { details["bytes"] = bytes }
            if let files { details["files"] = files }
            return details
        }
    }

    /// `cmux link start-chat preflight --local FOLDER`, before any machine or lease is made for a start: the refusal of a
    /// folder past the copy's limits, else nil (a pass, and also a check that could not run: the copy counts it again).
    public func startChatPreflight(local: String) async -> StartChatPreflightRefusal? {
        if case .refused(let refusal) = await startChatPreflightAnswer(local: local) { return refusal }
        return nil
    }

    /// The preflight's answer: a refusal, or the bytes the folder's copy will send and the size a machine needs for them.
    public enum StartChatPreflight: Sendable, Equatable {
        case refused(StartChatPreflightRefusal)
        /// `bytes`: what the copy sends (`estimate_bytes`); `size`: the chat size that holds it (`needed_size`), nil past
        /// the largest. Both nil when the preflight could not read the folder (a cmux-tui that answers no size).
        case passed(bytes: Int64?, size: CloudChatSize?)

        /// The answer an object names: a refusal (``StartChatPreflightRefusal``), else a pass with its fields.
        public init(answer: [String: Any]) {
            if let refusal = StartChatPreflightRefusal(answer: answer) { self = .refused(refusal); return }
            let bytes = (answer["estimate_bytes"] as? NSNumber)?.int64Value
            self = .passed(bytes: bytes, size: (answer["needed_size"] as? String).flatMap(CloudChatSize.init(rawValue:)))
        }

        /// The size to ask the machine's create for (nil: the chat size), or the start's refusal: a folder the largest
        /// chat size cannot hold is `cloud_folder_too_big` (`folder`: the folder as the person reads it), never a
        /// partial copy shown as complete.
        public func size(folder: String) throws -> CloudChatSize? {
            switch self {
            case .refused(let refusal): throw refusal
            case .passed(let bytes?, nil):
                throw StartChatPreflightRefusal(message: "\(folder) is too big for a Cloud machine", folder: folder, bytes: Double(bytes))
            case .passed(_, let size): return size
            }
        }
    }

    /// ``startChatPreflight(local:)`` with its size: a pass that could not run is a pass with no size.
    public func startChatPreflightAnswer(local: String) async -> StartChatPreflight {
        struct Call: Encodable { var verb = "start-chat-preflight"; var local: String }
        guard let read = try? await run(Call(local: local), reading: "reservation"), let object = read.object,
              let answer = try? JSONSerialization.jsonObject(with: object) as? [String: Any] else { return .passed(bytes: nil, size: nil) }
        return StartChatPreflight(answer: answer)
    }

    /// The start's machine size for the folder `local` (``StartChatPreflight/size(folder:)``), its refusal thrown.
    public func startChatSize(local: String) async throws -> CloudChatSize? {
        try await startChatPreflightAnswer(local: local).size(folder: Self.shownFolder(local))
    }

    /// `local` as the person reads it: under the home folder as `~/…`.
    public static func shownFolder(_ local: String, home: String = NSHomeDirectory()) -> String {
        local == home || local.hasPrefix(home + "/") ? "~" + local.dropFirst(home.count) : local
    }

    /// `cmux link seed push`: seeds `local` at `remote` from its GitHub remote plus one bundle, else copies it.
    /// `stderrLine` gets its progress lines (``SeedProgress/feed(_:each:)``).
    public func seedPush(socket: String, local: String, remote: String, stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> Answer {
        try await run(["verb": "seed-push", "socket": socket, "local": local, "remote": remote], stderrLine: stderrLine).answer
    }

    /// `cmux link seed pull --or-copy` (Bring Back Local); `stderrLine` as ``seedPush(socket:local:remote:stderrLine:)``'s.
    public func bringBackPull(socket: String, local: String, remote: String, stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> Answer {
        try await run(["verb": "bring-back-pull", "socket": socket, "local": local, "remote": remote], stderrLine: stderrLine).answer
    }

    /// `cmux link seed fetch --find-root`: the first copy of the machine's folder of a chat at `remote` (its
    /// repository root, when it is in one) in the new or empty folder `local` (Transfer to This Mac). `adopt` (the
    /// chat moves here) keeps the sync records on both sides, so the move's pull and Bring Back build on it.
    public func transferFetch(socket: String, local: String, remote: String, adopt: Bool) async throws -> Answer {
        struct Call: Encodable { var verb = "transfer-fetch"; var socket: String, local: String, remote: String, adopt: Bool }
        return try await run(Call(socket: socket, local: local, remote: remote, adopt: adopt)).answer
    }

    /// `cmux link agent move`: moves the chat of tab `surface` of the daemon at `from` to the machine daemon at `to`,
    /// in `cwd`; a running turn stops for the move and goes on where the chat lands. `sync` copies the folder's last
    /// changes once the chat is frozen, then `thenSync` (Move to Another Machine: a pull from the machine the chat
    /// leaves, then a seed of the one it goes to); `askFirst` narrows it to an asking policy first; `vmKind` is the
    /// Cloud API's answer for this app on the link in use. `login`: the owner's agent login, on stdin only
    /// (`--login-stdin`), which the machine starts the moved chat's agent with. `loginConnection` is the
    /// saved connection binding the guest records for withdrawal.
    public func agentMove(from: String, surface: UInt64, to: String, cwd: String, sync: FrozenSync? = nil, thenSync: FrozenSync? = nil,
                          askFirst: Bool = false, vmKind: String? = nil, toPID: Int32? = nil, login: [String: String]? = nil,
                          loginConnection: String? = nil) async throws -> Answer {
        struct Call: Encodable {
            var verb = "agent-move"
            var from: String, surface: UInt64, to: String, cwd: String, sync: FrozenSync?, thenSync: FrozenSync?, askFirst: Bool, vmKind: String?
            var toPid: Int32?
            var login: Bool
        }
        let stdin = try login.map { env in
            var credentials: [String: Any] = ["env": env]
            if let loginConnection { credentials["connection"] = loginConnection }
            return try JSONSerialization.data(withJSONObject: credentials)
        }
        return try await run(Call(from: from, surface: surface, to: to, cwd: cwd, sync: sync, thenSync: thenSync, askFirst: askFirst,
                                  vmKind: vmKind, toPid: toPID, login: login != nil), stdin: stdin).answer
    }

    /// `cmux link machine update`: updates the machine's cmux-tui to this app's own pinned build when it is outdated;
    /// `toBundled` whenever it runs another build, with `ifOlder` only when that build is older than this app's.
    /// `within`: the run ends (its process killed) after this at most, and answers ``machineUpdateAbandoned``: a chat start's own
    /// update, which a machine whose updater never takes an older build than it applied kept waiting for its 25-minute outcome while
    /// the start, and every later update in the app's one queue, waited behind it (2026-11-16).
    public func machineUpdate(socket: String, toBundled: Bool = false, ifOlder: Bool = false, within: Duration? = nil) async throws -> Answer {
        struct Call: Encodable { var verb = "machine-update"; var socket: String, toBundled: Bool, ifOlder: Bool }
        do {
            return try await run(Call(socket: socket, toBundled: toBundled, ifOlder: ifOlder), reading: "machine-update", limit: within).answer
        } catch let error as DaemonError {
            guard case .timedOut = error, let within else { throw error }
            return Answer(ok: false, errorCode: Self.machineUpdateAbandoned, error: "the update did not finish within \(within)")
        }
    }

    /// The error code of a ``machineUpdate(socket:toBundled:ifOlder:within:)`` run ended at its `within` bound: how the update
    /// ended is unknown, and the machine may still be on its own build.
    public static let machineUpdateAbandoned = "machine_update_abandoned"

    /// `cmux link machine pin`: its output, the Linux build this client pins (``CloudLegacyPin/pin(answer:)``).
    public func machinePin() async -> Data? { try? await output(["verb": "machine-pin"]).stdout }

    /// `cmux inference gateway status --json --team <team>`'s `serves` (Rust `status_answer`): the agents `team`'s inference
    /// gateway serves now, empty when it is off or offline; nil when the status could not be read (hq#15762). `team` is
    /// the backend team the start's machines are made in (the install token's): a team's gateway serves only its own
    /// machines, so the active team's would wave through a start no gateway serves.
    public func inferenceGatewayServes(team: String) async -> Set<String>? {
        await inferenceGatewayRead(team: team).serves
    }

    /// ``inferenceGatewayServes(team:)`` with why a read gave no `serves`: the status's own error code and message,
    /// or how the run ended (the start gate logs it, so a refused start says which read failed; hq cloud-chat-works).
    public func inferenceGatewayRead(team: String) async -> (serves: Set<String>?, why: String?) {
        let result: ProcessResult
        do { result = try await output(["verb": "inference-gateway-status", "team": team]) } catch { return (nil, "run: \(error)") }
        guard let answer = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            return (nil, "exit \(result.status), no JSON answer")
        }
        guard answer["ok"] as? Bool == true, let serves = answer["serves"] as? [String] else {
            let error = answer["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (answer["error_code"] as? String) ?? "-"
            let message = (error?["message"] as? String) ?? (answer["error"] as? String) ?? ""
            return (nil, "exit \(result.status) \(code) \(message.prefix(200))")
        }
        return (Set(serves), nil)
    }

    /// What the gateways of TEAMS serve together (nil teams skipped, each asked once), nil when none answers. A start's
    /// machine can land in either the install token's team or the person's own team: production made every
    /// cloud-chat-replies-production machine in the personal team while the install token named another (cmuxterm-hq
    /// probe rows 2026-11-22/23), and a gateway online there was refused as "No Cloud connection serves claude".
    public func inferenceGatewayServes(teams: [String?]) async -> Set<String>? {
        var asked: Set<String> = [], serves: Set<String>?
        for team in teams.compactMap({ $0 }) where asked.insert(team).inserted {
            if let answer = await inferenceGatewayServes(team: team) { serves = (serves ?? []).union(answer) }
        }
        return serves
    }

    /// Rust validates reservation fields; the native app supplies only its trusted origin/team.
    /// `install`: the install token, whose team Rust names the reservation in (the spare warm's, `install_team`).
    public func startChatReservation(release: Bool, request: String, access: String, install: String? = nil) async throws -> Data {
        struct Call: Encodable { var verb = "start-chat-reservation"; var release: Bool, request: String }
        let read = try await run(Call(release: release, request: request), reading: "reservation", stdin: Data((access + "\n" + (install ?? "") + "\n").utf8))
        return read.object ?? Data(#"{"ok":false,"error_code":"bad_answer"}"#.utf8)
    }

    /// The login copy a fresh spare warm asks for (``startChatWarmSpare(platform:account:access:install:)``): Rust's
    /// `copy`, answered only for a machine the person owns, in the backend team it warmed.
    public struct SpareWarm: Sendable, Equatable {
        public var machineID: String
        /// The account and the backend team (`team_…`, the install token's) the warm was asked for.
        public var account: String
        public var team: String
        /// Rust's attempt fence, returned unchanged when the copy completes.
        public var generation: String?

        public init(machineID: String, account: String, team: String, generation: String? = nil) {
            (self.machineID, self.account, self.team, self.generation) = (machineID, account, team, generation)
        }
    }

    /// How the App's login copy of a warm ended: installed (Rust keeps it as the start's login receipt), done otherwise
    /// (or given up for good), or abandoned to an account or team switch.
    public enum SpareWarmEnd: Sendable, Equatable { case installed(String), verified(String), finished(String), abandoned(String) }

    /// `cmux link start-chat warm-spare --request JSON`, the session `access` token then the `install` token on stdin:
    /// the person's spare, warmed in the install token's team (Rust's `install_team`, the reservation's). Nil when there is nothing to copy: an answer from
    /// the record, no spare, a machine they do not own, or a refusal. With `end`, it reports the copy's end instead:
    /// a start waiting on it goes on, and an abandoned copy is answered again by Rust's next warm.
    /// With `claimed`, it asks no warm: a reserve's or a claim's answer named that machine, and Rust answers the copy onto
    /// it unless a copy onto it is already in flight or given (keyed per machine, cmux-tui `spare_warm`).
    /// With `ready`, likewise no warm: the platform said that spare became ready, and Rust answers its copy the same way.
    public func startChatWarmSpare(platform: URL, account: String, access: String, install: String, end: SpareWarmEnd? = nil,
                                   claimed: String? = nil, ready: String? = nil, generation: String? = nil,
                                   scope: [String: String]? = nil, currentScope: [String: String]? = nil) async -> SpareWarm? {
        var request = Self.spareWarmRequest(platform: platform, account: account, end: end, claimed: claimed, ready: ready)
        request["generation"] = generation
        if let scope { request["scope"] = scope }
        if let currentScope { request["currentScope"] = currentScope }
        return Self.spareCopy(await spareWarmReply(request, access: access, install: install), account: account)
    }

    /// A warm's spare as Rust answered it: the machine it names and its team, and the login copy onto it when one is asked
    /// (``SpareWarm``). Not the owner's (`vm_kind` `team`): never made ready ahead (``CloudSpareReadiness``).
    public struct WarmedSpare: Sendable, Equatable {
        public var machineID: String
        public var team: String?
        public var copy: SpareWarm?
    }

    /// ``startChatWarmSpare(platform:account:access:install:end:claimed:ready:generation:scope:currentScope:)``'s warm,
    /// with the spare it named whether or not a copy is asked; nil with no spare, a teammate's, or a refusal.
    public func startChatWarmedSpare(platform: URL, account: String, access: String, install: String) async -> WarmedSpare? {
        let request = Self.spareWarmRequest(platform: platform, account: account, end: nil, claimed: nil)
        return Self.warmedSpare(await spareWarmReply(request, access: access, install: install), account: account)
    }

    /// The spare a warm's `reply` names (``WarmedSpare``).
    static func warmedSpare(_ reply: [String: Any]?, account: String) -> WarmedSpare? {
        guard let reply, reply["ok"] as? Bool == true, let machine = reply["machine"] as? String, !machine.isEmpty,
              ((reply["vm_kind"] as? String) ?? "owner") == "owner" else { return nil }
        return WarmedSpare(machineID: machine, team: reply["team"] as? String, copy: spareCopy(reply, account: account))
    }

    /// The login copy a warm's `reply` asks for, for `account` only.
    static func spareCopy(_ reply: [String: Any]?, account: String) -> SpareWarm? {
        guard let copy = reply?["copy"] as? [String: Any], let machineID = copy["machine"] as? String,
              copy["account"] as? String == account, let team = copy["team"] as? String else { return nil }
        return SpareWarm(machineID: machineID, account: account, team: team, generation: copy["generation"] as? String)
    }

    /// One `warm-spare` call's answer object; nil when it did not run or answer one.
    private func spareWarmReply(_ request: [String: Any], access: String, install: String) async -> [String: Any]? {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        guard let payload = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let read = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation",
                                        stdin: Data((access + "\n" + install + "\n").utf8)),
              let object = read.object else { return nil }
        return try? JSONSerialization.jsonObject(with: object) as? [String: Any]
    }

    /// The `warm-spare` request: a warm, the end of its copy (`end`), or the copy a reserve's or claim's machine asks for (`claimed`).
    static func spareWarmRequest(platform: URL, account: String, end: SpareWarmEnd?, claimed: String?, ready: String? = nil) -> [String: Any] {
        var request: [String: Any] = ["platform": platform.absoluteString, "account": account]
        switch end {
        case .installed(let machine): request["installed"] = machine
        case .verified(let machine): request["verified"] = machine
        case .finished(let machine): request["finished"] = machine
        case .abandoned(let machine): request["abandoned"] = machine
        case nil: request["claimed"] = claimed; request["ready"] = claimed == nil ? ready : nil
        }
        return request
    }

    /// The defaults key of ``copiesLoginOnClaim(_:)``.
    public static let copyLoginOnClaimKey = "cmux.cloud.copyLoginOnClaim"

    /// Whether a reserve's or a claim's machine starts the login copy onto that machine (cmux-platform#1084, item (a)).
    /// On unless `cmux.cloud.copyLoginOnClaim` is NO (Leo, 2026-11-09: "at least frontload the stuff that we can check earlier").
    public static func copiesLoginOnClaim(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: copyLoginOnClaimKey) as? Bool ?? true }

    /// The machine a reservation answer (``startChatReservation(release:request:access:install:)``, read as an object) reserved; nil for a refusal.
    public static func reservedMachine(_ reply: [String: Any]) -> String? {
        guard reply["ok"] as? Bool == true, let machine = reply["machine"] as? String, !machine.isEmpty else { return nil }
        return machine
    }

    /// A start's wait on a spare warm's login copy onto `machine` (Rust's `wait-copy`, at most 80 s): returns once no
    /// copy of `provider`'s login onto it is in flight, at once for a provider the warm does not copy.
    public func startChatWaitCopy(machine: String, provider: String) async {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        let wait: [String: Any] = ["account": "wait", "waitCopy": ["machine": machine, "provider": provider]]
        guard let payload = try? JSONSerialization.data(withJSONObject: wait, options: [.sortedKeys]) else { return }
        _ = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation", stdin: nil)
    }

    /// The teams the Cloud wire subscribes in (Rust's `wireTeams`, the `install` token on stdin): `active` first, then
    /// the install token's team when it is another. Nil on any failure (the caller keeps `active` alone).
    public func startChatWireTeams(active: String?, install: String?) async -> [String]? {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        let ask: [String: Any] = ["account": "wire", "wireTeams": active.map { ["active": $0] } ?? [String: String]()]
        guard let payload = try? JSONSerialization.data(withJSONObject: ask, options: [.sortedKeys]),
              let read = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation",
                                        stdin: Data(((install ?? "") + "\n").utf8)),
              let object = read.object, let reply = try? JSONSerialization.jsonObject(with: object) as? [String: Any],
              let teams = reply["teams"] as? [String] else { return nil }
        return teams
    }

    /// ``startChatWireTeams(active:install:)`` through `binary` with `identity`'s install token: nil without the CLI.
    public static func wireTeams(binary: URL?, identity: MacInstallIdentity, active: String?) async -> [String]? {
        guard let binary else { return nil }
        let install = try? await identity.installToken()
        return await CloudMoveCLI(binary: binary).startChatWireTeams(active: active, install: install)
    }

    /// Whether a warm installed `account`'s `provider` login on `machine` recently and no newer copy onto it is in flight
    /// (Rust's `loginReceipt`): the start then checks and passes no login of its own. False on any failure.
    public func startChatLoginReceipt(machine: String, account: String, provider: String, scope: [String: String]? = nil) async -> Bool {
        struct Call: Encodable { var verb = "start-chat-warm-spare"; var request: String }
        var ask: [String: Any] = ["account": account, "loginReceipt": ["machine": machine, "provider": provider]]
        if let scope { ask["scope"] = scope }
        guard let payload = try? JSONSerialization.data(withJSONObject: ask, options: [.sortedKeys]),
              let read = try? await run(Call(request: String(decoding: payload, as: UTF8.self)), reading: "reservation", stdin: nil),
              let object = read.object, let reply = try? JSONSerialization.jsonObject(with: object) as? [String: Any] else { return false }
        return reply["installed"] as? Bool == true
    }

    /// `cmux link start-chat plan --request JSON`, the cmux `access` token on stdin.
    /// `install`: a reserved send's install token, whose team Rust binds the reservation in (`install_team`).
    public func startChatPlan(request: String, access: String? = nil, install: String? = nil) async throws -> (Answer, StartChatPlan) {
        let read = try await run(["verb": "start-chat-plan", "request": request], reading: "start-chat-plan", stdin: access.map { Data(($0 + "\n" + (install.map { $0 + "\n" } ?? "")).utf8) })
        return (read.answer, read.plan ?? StartChatPlan(createKey: "", tabKey: ""))
    }

    /// A new machine in the cloud environment `environment` (`env_…`, the `/v1/cloud-environments` store): the platform's
    /// workspace ensure (`cmux link start-chat ensure --environment`), which injects the environment's variables and runs
    /// its setup. The wire's `cloud.environment.boot` is not live on cmux-api or cmux-platform (`CLOUD_LIVE_OPS`), and it
    /// reads CloudDO's own table, which holds none of these. `key`'s UUID part is the ensure's workspace and client key, so
    /// a Retry with the same key gets the same machine; `access` is the person's cmux access token (stdin). The machine's id.
    public func machineInEnvironment(_ environment: String, key: String, platform: String?, access: String) async throws -> String {
        var call = ["verb": "start-chat-ensure", "key": String(key.suffix(36)), "environment": environment]
        call["platform"] = platform
        let read = try await run(call, reading: "reservation", stdin: Data((access + "\n").utf8))
        let object = read.object.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        guard read.answer.ok, let id = object?["machine"]?.stringValue else {
            throw CloudAppOpFailure(code: read.answer.errorCode ?? "cmux.cloud.bad_response", message: read.answer.error ?? "the workspace ensure answered no machine")
        }
        if let selected = object?["selected_environment"]?.stringValue, selected != environment {
            throw CloudAppOpFailure(code: "environment_mismatch", message: "The chosen machine cannot serve the selected Cloud environment.")
        }
        return id
    }

    /// `cmux link start-chat pin`: the send `key` of `account` runs on `machine`, one the App just made for it.
    public func startChatPin(key: String, account: String, machine: String, workspace: String?) async throws -> (Answer, Void) {
        var call = ["verb": "start-chat-pin", "key": key, "account": account, "machine": machine]
        call["workspace"] = workspace
        return (try await run(call).answer, ())
    }

    /// `cmux link start-chat strand`: the start of the send `key` can't go on and gives up `machine`, the one made for
    /// it. True only when no other send is on the machine, so the App may delete it (under the ledger lock later sends
    /// pin under, so a chat that took the machine first keeps it). Any failure answers false: nothing is deleted.
    public func startChatStrand(key: String, account: String, machine: String) async -> Bool {
        struct Reply: Decodable { var ok: Bool; var delete: Bool? }
        guard let read = try? await run(["verb": "start-chat-strand", "key": key, "account": account, "machine": machine], reading: "reservation"),
              let object = read.object, let reply = try? JSONDecoder().decode(Reply.self, from: object) else { return false }
        return reply.ok && reply.delete == true
    }

    /// Gives up `machine`, made for the start of send `key`, and runs `delete` on it only when ``startChatStrand(key:account:machine:)``
    /// says no other send took it meanwhile: a second chat of the workspace that planned onto it keeps it and its files.
    @MainActor public func strandThenDelete(key: String, account: String, machine: String, delete: @MainActor (String) async throws -> Void) async throws {
        if await startChatStrand(key: key, account: account, machine: machine) { try await delete(machine) }
    }

    public func startChatCreateBegin(key: String, account: String, name: String, createKey: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-create-begin", "key": key, "account": account, "name": name, "createKey": createKey]).answer, ())
    }

    /// `route`: how the create goes out, kept with its key (``StartChatPlan/recorded(_:)``; nil names none, the relay).
    /// A key already sent on the other route is refused, before anything goes out.
    public func startChatCreateSent(key: String, account: String, team: String, createKey: String, route: CloudCreateRoute? = nil) async throws -> (Answer, Void) {
        var call = ["verb": "start-chat-create-sent", "key": key, "account": account, "team": team, "createKey": createKey]
        if let route { call["route"] = route.rawValue }
        return (try await run(call).answer, ())
    }

    public func startChatCreateRefused(key: String, account: String, createKey: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-create-refused", "key": key, "account": account, "createKey": createKey]).answer, ())
    }

    public func startChatTargetPane(key: String, account: String, machine: String, pane: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-target-pane", "key": key, "account": account, "machine": machine, "pane": pane]).answer, ())
    }

    /// `cmux link start-chat import`: hands cmux-tui the sends this App kept itself before (`entries`, their JSON).
    public func startChatImport(entries: String) async throws -> (Answer, Void) {
        (try await run(["verb": "start-chat-import", "entries": entries]).answer, ())
    }

    /// `cmux link start-chat copy`: copies `local` to a folder of the send's own on the machine `socket` reaches, under the
    /// first of `workRoots` it can write, unless this send's copy already finished there. With the cmux `access` token
    /// (on stdin) it goes through the content-addressed store. The chat's folder there, whether it copied now, and
    /// whether this Mac's acpmux (home `acpmuxHome`) trusts the chat's folder here. `onSeedRefusal` says what it does
    /// when the machine can't clone the folder from its git remote.
    public func startChatCopy(key: String, account: String, machine: String, socket: String, local: String, subpath: String,
                              workRoots: [String], acpmuxHome: String?, access: String? = nil, onSeedRefusal: SeedRefusal = .copy,
                              stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> (Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool)) {
        let call = StartChatCopyCall(key: key, account: account, machine: machine, socket: socket, local: local, subpath: subpath,
                                     workRoots: workRoots, acpmuxHome: acpmuxHome, store: access != nil, onSeedRefusal: onSeedRefusal)
        let read = try await run(call, reading: "start-chat-copy", stdin: access.map { Data(($0 + "\n").utf8) }, stderrLine: stderrLine)
        let copy = read.copy
        return (read.answer, (copy?.chat ?? "", copy?.folder ?? "", copy?.copied ?? false, copy?.sourceTrusted ?? false))
    }

    /// `cmux link start-chat trust`: the level this Mac's acpmux (home `acpmuxHome`) answers for `folder`
    /// (`trusted`, `untrusted` or `unknown`), read before any machine is taken: a start's copy is trusted on its
    /// machine only when this Mac trusts the folder. Nil when it could not be read (the start goes on, as before).
    public func startChatTrust(folder: String, acpmuxHome: String) async -> String? {
        struct Call: Encodable { var verb = "start-chat-trust"; var folder: String, acpmuxHome: String }
        return try? await run(Call(folder: folder, acpmuxHome: acpmuxHome), reading: "start-chat-trust").trust?.level
    }

    /// What a start copy does when the machine can't clone the folder from its git remote
    /// (cmux-tui `--on-seed-refusal`): `ask` answers `seed_refused` with the reason and what a copy
    /// would send, and copies nothing; `copy` copies the folder instead.
    public enum SeedRefusal: String, Sendable, Encodable {
        case ask, copy
    }

    /// `link start-chat copy`'s arguments, as Rust names them (`store`: the cmux access token is on stdin).
    public static func startChatCopyArguments(key: String, account: String, machine: String, socket: String, local: String, subpath: String,
                                              workRoots: [String], acpmuxHome: String?, store: Bool, onSeedRefusal: SeedRefusal) -> [String] {
        let call = StartChatCopyCall(key: key, account: account, machine: machine, socket: socket, local: local, subpath: subpath,
                                     workRoots: workRoots, acpmuxHome: acpmuxHome, store: store, onSeedRefusal: onSeedRefusal)
        return Self.withSeedRefusal(CloudMoveCore().call("cli_invocation", call, as: Invocation.self)?.args ?? [], call)
    }

    /// TRANSITIONAL until CCmuxAppFFI is repinned past cmux-cloud-start-core's `on_seed_refusal`: the pinned release
    /// names no `--on-seed-refusal`, so the copy's own rule is added here. A library that names it is left as it said.
    private static func withSeedRefusal<Call: Encodable>(_ args: [String], _ call: Call) -> [String] {
        guard let copy = call as? StartChatCopyCall, !args.isEmpty, !args.contains("--on-seed-refusal") else { return args }
        return args + ["--on-seed-refusal", copy.onSeedRefusal.rawValue]
    }

    /// TRANSITIONAL with ``withSeedRefusal(_:_:)``: the pinned release does not read a refused seed's `fallback_code`,
    /// `install_url` and `copy_bytes`, so they come from the answer's own JSON line when Rust left them out.
    private static func withSeedFields(_ answer: Answer, stdout: String) -> Answer {
        guard answer.fallbackCode == nil || answer.copyBytes == nil || answer.machineTitle == nil else { return answer }
        struct Fields: Decodable {
            var fallbackCode: String?, installURL: String?, copyBytes: Int64?, machineTitle: String?
            enum CodingKeys: String, CodingKey { case fallbackCode = "fallback_code", installURL = "install_url", copyBytes = "copy_bytes", machineTitle = "machine_title" }
        }
        let line = stdout.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }
        guard let line, let fields = try? JSONDecoder().decode(Fields.self, from: Data(line.utf8)) else { return answer }
        var answer = answer
        (answer.fallbackCode, answer.installURL, answer.copyBytes) = (answer.fallbackCode ?? fields.fallbackCode, answer.installURL ?? fields.installURL, answer.copyBytes ?? fields.copyBytes)
        answer.machineTitle = answer.machineTitle ?? fields.machineTitle
        return answer
    }

    private struct StartChatCopyCall: Encodable {
        var verb = "start-chat-copy"
        var key: String, account: String, machine: String, socket: String, local: String, subpath: String
        var workRoots: [String], acpmuxHome: String?, store: Bool, onSeedRefusal: SeedRefusal
    }

    /// What Rust read of one run.
    private struct Read: Decodable {
        struct Copy: Decodable { var chat: String, folder: String, copied: Bool, sourceTrusted: Bool }
        struct Trust: Decodable { var level: String? }
        var answer: Answer
        var plan: StartChatPlan?
        var copy: Copy?
        var trust: Trust?
        /// The reservation's answer object, as JSON.
        var object: Data?

        enum CodingKeys: String, CodingKey { case answer, plan, copy, trust, object }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            answer = try container.decode(Answer.self, forKey: .answer)
            plan = try container.decodeIfPresent(StartChatPlan.self, forKey: .plan)
            copy = try container.decodeIfPresent(Copy.self, forKey: .copy)
            trust = try container.decodeIfPresent(Trust.self, forKey: .trust)
            object = try container.decodeIfPresent(JSONValue.self, forKey: .object).flatMap { try? JSONEncoder().encode($0) }
        }

        init(answer: Answer) { self.answer = answer }
    }

    /// One run's output, for Rust to read.
    private struct ReadRequest: Encodable { var reading: String, stdout: String, stderr: String, status: Int32 }

    /// How Rust says to run a call.
    private struct Invocation: Decodable { var args: [String], timeoutSeconds: Int?, minTimeoutSeconds: Int? }

    /// `bound`: a caller's shorter limit for this one run (``machineUpdate(socket:toBundled:ifOlder:within:)``).
    private func output<Call: Encodable>(_ call: Call, stdin: Data? = nil, stderrLine: (@Sendable (String) -> Void)? = nil,
                                         bound: Duration? = nil) async throws -> ProcessResult {
        guard let invocation = CloudMoveCore().call("cli_invocation", call, as: Invocation.self) else { throw CloudMoveCLIUnanswered() }
        let own = invocation.timeoutSeconds.map { Duration.seconds($0) } ?? max(timeout, .seconds(invocation.minTimeoutSeconds ?? 0))
        let limit = bound.map { min($0, own) } ?? own
        return try await ProcessRunner.run(executable: binary, arguments: Self.withSeedRefusal(invocation.args, call), environment: nil, stdin: stdin,
                                           timeout: limit, stderrLine: stderrLine, clock: ContinuousClock())
    }

    private func run<Call: Encodable>(_ call: Call, reading: String = "plain", stdin: Data? = nil,
                                      stderrLine: (@Sendable (String) -> Void)? = nil, limit: Duration? = nil) async throws -> Read {
        let result = try await output(call, stdin: stdin, stderrLine: stderrLine, bound: limit)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let request = ReadRequest(reading: reading, stdout: stdout,
                                  stderr: String(decoding: result.stderr, as: UTF8.self), status: result.status)
        var read = CloudMoveCore().call("cli_read", request, as: Read.self)
            ?? Read(answer: Answer(ok: false, errorCode: Self.badAnswer, error: "exit \(result.status)"))
        read.answer = Self.withSeedFields(read.answer, stdout: stdout)
        if reading == "start-chat-plan", read.answer.ok, read.plan?.ensuredEnvironment == nil,
           let line = stdout.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }),
           let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) {
            read.plan?.ensuredEnvironment = reply["ensured"]?["selected_environment"]?.stringValue
        }
        return read
    }
}

/// The app FFI did not name a CLI call's arguments.
struct CloudMoveCLIUnanswered: Error {}
