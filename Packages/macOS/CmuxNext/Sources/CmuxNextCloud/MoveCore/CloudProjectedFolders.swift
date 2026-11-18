import CmuxNextCompat
import CmuxNextWakeups
public import Foundation
import os

/// The app's projected folders (`cloud.projectedFolders`, off by default): a Cloud chat whose folder is past what a copy
/// sends whole starts on a projection of it (``CloudMoveCLI/startChatProject(key:account:machine:socket:local:subpath:workRoots:)``),
/// and this owns the one `cmux link start-chat project-serve` child per mount that answers the machine's reads from this
/// Mac for as long as the chat runs.
///
/// A start projects only with the setting on and a folder past the copy's limits (``CloudMoveCLI/pastCopyLimits(_:)``);
/// any refusal (`fallback: copy`) is logged and the start copies the folder as it does with the setting off
/// (``start(on:cli:key:account:machine:socket:local:subpath:workRoots:acpmuxHome:)``).
///
/// A child that exits on its own starts again after a growing wait on the injected clock (at most 30 s); one that says
/// its record is gone (`record_missing`) is not started again. The ``CloudService`` that owns this ends the children
/// with the rest of the account's Cloud children: every machine list (``listed(machines:destroyed:account:current:)``)
/// adopts this account's records of listed machines (so a launch serves again what the last one served) and stops the
/// mounts of a machine two lists in a row left out; a record is removed only for a machine known destroyed (a list
/// that says so, or ``destroyed(_:)``), never for one a list merely left out; a sign-out or an account switch stops
/// them all (``stopAll()``); app quit stops them and waits for their exits (``stopAllAndWait()``).
@MainActor
public final class CloudProjectedFolders {
    /// One running `project-serve` child: its stdout lines, its exit status, and its SIGTERM.
    public struct Child: Sendable {
        public var lines: AsyncStream<String>
        public var exited: @Sendable () async -> Int32
        public var stop: @Sendable () -> Void

        public init(lines: AsyncStream<String>, exited: @escaping @Sendable () async -> Int32, stop: @escaping @Sendable () -> Void) {
            (self.lines, self.exited, self.stop) = (lines, exited, stop)
        }
    }

    /// A mount's `record.json` on this Mac (cmux-tui `projected::Record`), as far as the app reads it.
    public struct Record: Sendable, Equatable, Decodable {
        public var mount: String
        /// ``CloudStartCore/accountText(_:)`` of the account that projected it.
        public var account: String
        public var machine: String
        public var localRoot: String
        public var machinePath: String
        /// The mounted folder on the machine (the chat's copy folder, as ``CloudMovedChats`` keeps it).
        public var folder: String

        public init(mount: String, account: String, machine: String, localRoot: String, machinePath: String, folder: String) {
            (self.mount, self.account, self.machine, self.localRoot, self.machinePath, self.folder) = (mount, account, machine, localRoot, machinePath, folder)
        }

        enum CodingKeys: String, CodingKey { case mount, account, machine, localRoot = "local_root", machinePath = "machine_path", folder }
    }

    /// A start's answer on a projection, in the shape of ``CloudMoveCLI/startChatCopy(key:account:machine:socket:local:subpath:workRoots:acpmuxHome:access:onSeedRefusal:stderrLine:)``'s:
    /// an ok answer with nothing left on this Mac, the chat's folder and the mounted folder on the machine.
    public typealias Started = (CloudMoveCLI.Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool))

    private struct Served {
        var record: Record
        var generation: Int
        var child: Child?
        var restart: Task<Void, Never>?
        var relaunch = Backoff(initial: .seconds(1), maximum: .seconds(30))
        /// The machine lists in a row that left its machine out.
        var missed = 0
    }

    private let launch: @MainActor (Record) async -> Child?
    private let clock: any Clock<Duration>
    /// Where cmux-tui keeps the records (`<state>/cloud-start-chat/projected`); nil: none is read or removed.
    private let folder: URL?
    private var served: [String: Served] = [:]
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.projected")

    /// - Parameter launch: Starts the serve child of one record; nil when this build has no `cmux` or it could not start.
    public init(folder: URL?, clock: any Clock<Duration> = ContinuousClock(), launch: @escaping @MainActor (Record) async -> Child?) {
        (self.folder, self.clock, self.launch) = (folder, clock, launch)
    }

    /// The live owner: `binary` (the app's `cmux`, ``CloudMoveCLI/binary``) run with the app's environment, as every
    /// other Cloud CLI call runs it, so its records are the ones `project` kept.
    public convenience init(binary: URL?, environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        self.init(folder: Self.recordsFolder(environment: environment, home: home)) { record in
            guard let binary else { return nil }
            let process = ChildProcess(executable: binary, arguments: CloudMoveCLI.startChatProjectServeArguments(mount: record.mount), environment: environment)
            do { try process.start() } catch { return nil }
            return Child(lines: process.lines, exited: { await process.waitForExit() }, stop: { process.terminate() })
        }
    }

    /// cmux-tui's records folder: `<CMUX_TUI_STATE_DIR or ~/Library/Application Support/cmux-tui/sessions>/cloud-start-chat/projected`.
    public nonisolated static func recordsFolder(environment: [String: String], home: String) -> URL {
        let state = environment["CMUX_TUI_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/Library/Application Support/cmux-tui/sessions"
        return URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("cloud-start-chat/projected", isDirectory: true)
    }

    /// The mounts served now.
    public var mounts: Set<String> { Set(served.keys) }

    /// The projection a chat's copy folder `folder` on `machine` is, while it is served; nil for a copied folder.
    public func record(machine: String, folder: String) -> Record? {
        served.values.first { $0.record.machine == machine && $0.record.folder == folder }?.record
    }

    /// A Cloud start's folder on a projection, or nil for the copy: nil unless `on` (`cloud.projectedFolders`), the
    /// machine's `socket` is known and the folder is past the copy's limits; nil too, logged, when `project` refuses or
    /// fails. A projection starts its serve child and is trusted on the machine as the copy would be (`acpmuxHome`).
    ///
    /// `tooBig` is the size refusal the start let this folder past only so that it could be projected
    /// (``AgentPaneCloudStart/sized(_:local:projecting:)``): with no projection that refusal stands and is thrown, so a
    /// folder no machine holds is never copied onto one.
    public func start(on: Bool, cli: CloudMoveCLI, key: String, account: String, machine: String, socket: String?, local: String,
                      subpath: String, workRoots: [String], acpmuxHome: String?,
                      tooBig: CloudMoveCLI.StartChatPreflightRefusal? = nil) async throws -> Started? {
        guard let started = await projected(on: on, cli: cli, key: key, account: account, machine: machine, socket: socket, local: local,
                                            subpath: subpath, workRoots: workRoots, acpmuxHome: acpmuxHome, pastLimits: tooBig != nil) else {
            if let tooBig { throw tooBig }
            return nil
        }
        return started
    }

    private func projected(on: Bool, cli: CloudMoveCLI, key: String, account: String, machine: String, socket: String?, local: String,
                           subpath: String, workRoots: [String], acpmuxHome: String?, pastLimits: Bool) async -> Started? {
        guard on, let socket else { return nil }
        // The start's own preflight already said so when it refused the size; else cmux-tui answers again from the
        // decision it keeps for two minutes.
        if !pastLimits {
            guard await cli.startChatPastCopyLimits(local: local) else { return nil }
        }
        let projection: CloudMoveCLI.StartChatProjection
        do {
            projection = try await cli.startChatProject(key: key, account: account, machine: machine, socket: socket, local: local,
                                                        subpath: subpath, workRoots: workRoots)
        } catch let refusal as CloudMoveCLI.StartChatProjectRefusal {
            logger.notice("projected folder refused (\(refusal.code, privacy: .public)): the start copies the folder")
            return nil
        } catch {
            logger.error("projected folder did not run (\(String(describing: type(of: error)), privacy: .public)): the start copies the folder")
            // It may have kept its record before it was stopped: a record of this send that nothing serves would be
            // adopted by the next machine list and served for a mount no chat uses.
            if let folder { await Self.remove(await Self.records(in: folder).filter { Self.kept($0, by: key, machine: machine, local: local) }.map(\.mount), in: folder) }
            return nil
        }
        serve(Record(mount: projection.mount, account: account, machine: machine, localRoot: local, machinePath: projection.machinePath,
                     folder: projection.folder))
        logger.info("projected folder \(projection.mount, privacy: .public): \(projection.entries ?? 0) entries")
        let chat = subpath.isEmpty ? local : local + "/" + subpath
        var trusted = false
        if let acpmuxHome { trusted = await cli.startChatTrust(folder: chat, acpmuxHome: acpmuxHome) == "trusted" }
        return (CloudMoveCLI.Answer(ok: true), (chat: projection.machinePath, folder: projection.folder, copied: true, sourceTrusted: trusted))
    }

    /// Whether `record` is the one a `project` of the send `key` keeps for `local` on `machine` (cmux-tui names the
    /// mount `p-<key, lowercased>-<8 hex>`).
    nonisolated static func kept(_ record: Record, by key: String, machine: String, local: String) -> Bool {
        record.machine == machine && record.localRoot == local && record.mount.hasPrefix("p-" + key.lowercased() + "-")
    }

    /// A Bring Back's pull of the chat folder `folder` on `machine`: `project-pull` for a projection, else `orCopy`
    /// (Bring Back's own `link seed pull`). Both answer in the same shape. A file changed on both sides is a
    /// `sync_conflict` naming it, as the copy's pull names one (both versions are on this Mac by then, the machine's
    /// beside the file, and the next pull goes on). A path the pull would not write here (a secret, an ignored file,
    /// a kind it cannot hold) never stops the bring back: a copy's pull leaves those on the machine too.
    public func pull(machine: String, folder: String, socket: String, cli: CloudMoveCLI,
                     orCopy: () async throws -> CloudMoveCLI.Answer) async throws -> CloudMoveCLI.Answer {
        guard let record = await projection(machine: machine, folder: folder) else { return try await orCopy() }
        let pulled = try await cli.startChatProjectPull(mount: record.mount, socket: socket)
        if pulled.ok, !pulled.refused.isEmpty { logger.notice("projected folder \(record.mount, privacy: .public): \(pulled.refused.count) path(s) stay on the machine") }
        return pulled.answer
    }

    /// The pull that follows a bring back's move: what the machine wrote between ``pull(machine:folder:socket:cli:orCopy:)``
    /// and the chat's freeze (a turn that was still running) comes back too. The chat is on this Mac by now, so nothing
    /// here fails the bring back: a conflict's two versions are both on this Mac, and a pull that did not run is logged.
    public func settle(machine: String, folder: String, socket: String, cli: CloudMoveCLI) async {
        guard let record = await projection(machine: machine, folder: folder) else { return }
        do {
            let pulled = try await cli.startChatProjectPull(mount: record.mount, socket: socket)
            if !pulled.ok || !pulled.conflicts.isEmpty || !pulled.refused.isEmpty {
                logger.notice("projected folder \(record.mount, privacy: .public) after the move: ok \(pulled.ok), \(pulled.conflicts.count) kept beside, \(pulled.refused.count) left on the machine (\(pulled.code ?? "", privacy: .public))")
            }
        } catch {
            logger.error("projected folder \(record.mount, privacy: .public) after the move: the pull did not run (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// The projection `folder` on `machine` is: the served one, else its record on this Mac (a serve child that
    /// could not start, or a launch whose machine list has not adopted it yet), which is then served again.
    private func projection(machine: String, folder: String) async -> Record? {
        if let served = record(machine: machine, folder: folder) { return served }
        guard let records = self.folder,
              let kept = await Self.records(in: records).first(where: { $0.machine == machine && $0.folder == folder }) else { return nil }
        serve(kept)
        return kept
    }

    /// Serves `record`'s mount (once; a served mount stays).
    public func serve(_ record: Record) {
        guard Self.plain(record.mount), served[record.mount] == nil else { return }
        served[record.mount] = Served(record: record, generation: 0)
        spawn(record.mount)
    }

    /// Stops `mount`'s child (SIGTERM) and waits for it to exit.
    public func stop(_ mount: String) async {
        guard let entry = served.removeValue(forKey: mount) else { return }
        entry.restart?.cancel()
        entry.child?.stop()
        if let child = entry.child { _ = await child.exited() }
    }

    /// Sign-out or account switch: SIGTERM to every child; none starts again.
    public func stopAll() {
        for entry in served.values { entry.restart?.cancel(); entry.child?.stop() }
        served = [:]
    }

    /// App quit: ``stopAll()``, then each child's exit.
    public func stopAllAndWait() async {
        let children = served.values.compactMap(\.child)
        stopAll()
        for child in children { _ = await child.exited() }
    }

    /// A machine list for `account` (``CloudStartCore/accountText(_:)``) that names `machines` as there and `destroyed`
    /// as gone: its records of listed machines are served (a launch adopts what the last one served). A machine the
    /// list leaves out may still exist (a list fetched before the machine was made, a row the service filters), so
    /// its mount stops only after two lists in a row left it out, and its record stays: only `destroyed` removes one.
    /// Another account's records stay as they are. `current` says the list is still the signed-in account's after the
    /// records are read (a sign-out or a switch meanwhile serves nothing).
    public func listed(machines: Set<String>, destroyed: Set<String> = [], account: String, current: @MainActor () -> Bool) async {
        for machine in destroyed { _ = await self.destroyed(machine)?.value }
        // SIGTERM only: a list never waits on a child's exit.
        for mount in Array(served.keys) {
            guard var entry = served[mount] else { continue }
            entry.missed = machines.contains(entry.record.machine) ? 0 : entry.missed + 1
            served[mount] = entry
            guard entry.missed >= 2 else { continue }
            entry.restart?.cancel()
            entry.child?.stop()
            served[mount] = nil
        }
        guard let folder else { return }
        let records = await Self.records(in: folder).filter { $0.account == account }
        guard current() else { return }
        for record in records where machines.contains(record.machine) { serve(record) }
    }

    /// `machine` is destroyed (the service said so): its mounts stop and their records on this Mac are removed. The
    /// removal runs off the main actor; its task is handed back for a caller that waits for it.
    @discardableResult
    public func destroyed(_ machine: String) -> Task<Void, Never>? {
        for entry in served.values where entry.record.machine == machine {
            entry.restart?.cancel()
            entry.child?.stop()
            served[entry.record.mount] = nil
        }
        guard let folder else { return nil }
        // task-owner: CloudProjectedFolders.destroyed: one bounded removal of a destroyed machine's record folders, off the main actor.
        return Task { await Self.remove(await Self.records(in: folder).filter { $0.machine == machine }.map(\.mount), in: folder) }
    }

    private func spawn(_ mount: String) {
        generation += 1
        let mine = generation
        guard var entry = served[mount] else { return }
        entry.generation = mine
        entry.restart = nil
        served[mount] = entry
        // task-owner: CloudProjectedFolders.spawn: one child's life; stop() and stopAll() fence it by generation.
        Task { [weak self] in
            guard let self, let record = self.served[mount]?.record else { return }
            guard let child = await self.launch(record) else {
                if self.served[mount]?.generation == mine { self.served[mount] = nil; self.logger.error("project-serve could not start for \(mount, privacy: .public)") }
                return
            }
            guard self.served[mount]?.generation == mine else { child.stop(); return }
            self.served[mount]?.child = child
            var missing = false
            for await line in child.lines where Self.recordMissing(line) { missing = true }
            self.ended(mount, mine, status: await child.exited(), missing: missing)
        }
    }

    private func ended(_ mount: String, _ which: Int, status: Int32, missing: Bool) {
        guard var entry = served[mount], entry.generation == which else { return }
        if missing {
            served[mount] = nil
            logger.notice("project-serve \(mount, privacy: .public): its record is gone; not served again")
            return
        }
        entry.child = nil
        let delay = entry.relaunch.next()
        logger.notice("project-serve \(mount, privacy: .public) exited (\(status)); again in \(delay.inSeconds) s")
        // task-owner: CloudProjectedFolders.ended: one relaunch per exit after a growing wait; stop() and stopAll() cancel it.
        entry.restart = Task { [weak self, clock] in
            // wakeup-allow: one-shot relaunch wait after a serve child exited.
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled, self.served[mount]?.generation == which else { return }
            self.spawn(mount)
        }
        served[mount] = entry
    }

    /// A line of `project-serve` that says its record is gone (`{"ok":false,"code":"record_missing",...}`).
    nonisolated static func recordMissing(_ line: String) -> Bool {
        struct Line: Decodable { var code: String? }
        return (try? JSONDecoder().decode(Line.self, from: Data(line.utf8)))?.code == "record_missing"
    }

    /// A mount id as cmux-tui and the machine's daemon check it: never a path.
    nonisolated static func plain(_ mount: String) -> Bool {
        (1...64).contains(mount.utf8.count) && mount != "." && mount != ".."
            && mount.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// Every readable record under `folder` (one folder per mount), off the main actor.
    @concurrent nonisolated static func records(in folder: URL) async -> [Record] {
        let mounts = (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? []
        return mounts.filter(plain).compactMap { mount in
            let file = folder.appendingPathComponent(mount, isDirectory: true).appendingPathComponent("record.json", isDirectory: false)
            guard let data = try? Data(blockingContentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data), record.mount == mount else { return nil }
            return record
        }
    }

    /// Removes the record folders of `mounts` under `folder`, off the main actor.
    @concurrent nonisolated static func remove(_ mounts: [String], in folder: URL) async {
        for mount in mounts where plain(mount) { try? FileManager.checked.removeItem(at: folder.appendingPathComponent(mount, isDirectory: true)) }
    }
}
