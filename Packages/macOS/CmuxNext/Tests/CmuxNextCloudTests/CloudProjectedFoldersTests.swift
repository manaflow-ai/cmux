@testable import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Projected folders (`cloud.projectedFolders`): the CLI calls' arguments and answers, the rule that picks a projection
/// over a copy, the start that falls back to the copy on any refusal, the serve children's lives (restart on an injected
/// clock, stop, sign-out, quit), the records adopted or removed by a machine list, and the way back.
@MainActor
@Suite
struct CloudProjectedFoldersTests {
    /// Serve children the test drives: each launch is announced; `stop` ends its lines (as SIGTERM ends the process).
    @MainActor
    final class Children {
        var live: [AsyncStream<String>.Continuation] = []
        var launched: [String] = []
        let launches: AsyncStream<Int>
        private let announce: AsyncStream<Int>.Continuation
        let stops: AsyncStream<String>
        private let stopped: AsyncStream<String>.Continuation

        init() {
            (launches, announce) = AsyncStream.makeStream(of: Int.self)
            (stops, stopped) = AsyncStream.makeStream(of: String.self)
        }

        func launch(_ record: CloudProjectedFolders.Record) -> CloudProjectedFolders.Child {
            let (lines, continuation) = AsyncStream.makeStream(of: String.self)
            live.append(continuation)
            launched.append(record.mount)
            announce.yield(live.count)
            let stopped = stopped
            return CloudProjectedFolders.Child(lines: lines, exited: { 0 }, stop: { stopped.yield(record.mount); continuation.finish() })
        }

        /// The current child ends by itself (a crash, a kill from outside).
        func exitOnItsOwn() { live.last?.finish() }
    }

    private func record(_ mount: String, account: String = "u/", machine: String = "vm-1") -> CloudProjectedFolders.Record {
        .init(mount: mount, account: account, machine: machine, localRoot: "/Users/me/big", machinePath: "/w/chats/k/1/big", folder: "/w/chats/k/1/big")
    }

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-projected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `cmux` that answers `preflight`, `project` and `project-pull` with the given lines and logs each verb it ran.
    private func fakeCLI(in dir: URL, preflight: String, project: String = "", pull: String = "") throws -> (CloudMoveCLI, URL) {
        let binary = dir.appendingPathComponent("cmux"), calls = dir.appendingPathComponent("calls")
        let script = """
        #!/bin/sh
        echo "$3" >> '\(calls.path)'
        case "$3" in
        preflight) echo '\(preflight)' ;;
        project) echo '\(project)'; exit 1 ;;
        project-pull) echo '\(pull)' ;;
        esac
        """
        try (script + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (CloudMoveCLI(binary: binary, timeout: .seconds(20)), calls)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func theCallsNameCopysArgumentsAndTheMount() {
        let project = CloudMoveCLI.startChatProjectArguments(key: "k", account: "a/", machine: "vm", socket: "/s", local: "/l", subpath: "sub",
                                                             workRoots: ["/home/cmux/work", "/root/work"])
        #expect(project == ["link", "start-chat", "project", "--key", "k", "--account", "a/", "--machine", "vm", "--socket", "/s",
                            "--local", "/l", "--subpath", "sub", "--work-root", "/home/cmux/work", "--work-root", "/root/work"])
        #expect(CloudMoveCLI.startChatProjectServeArguments(mount: "p-k-1") == ["link", "start-chat", "project-serve", "--mount", "p-k-1"])
        #expect(CloudMoveCLI.startChatProjectServeArguments(mount: "p-k-1", socket: "/s").suffix(2) == ["--socket", "/s"])
        #expect(CloudMoveCLI.startChatProjectPullArguments(mount: "p-k-1", socket: "/s") == ["link", "start-chat", "project-pull", "--mount", "p-k-1", "--socket", "/s"])
    }

    /// Only a folder past what a copy sends whole is projected: a first pass, a folder no machine holds, an older
    /// cmux-tui's `copy.too_large`. A whole copy, a seed a machine holds and an unread estimate copy as before.
    @Test func onlyAFolderPastTheCopysLimitsIsProjected() {
        #expect(CloudMoveCLI.pastCopyLimits(["ok": true, "estimate": ["mode": "first_pass"], "estimate_bytes": 30, "needed_size": "sm"]))
        #expect(CloudMoveCLI.pastCopyLimits(["ok": true, "estimate": ["mode": "whole"], "estimate_bytes": 300, "needed_size": NSNull()]))
        #expect(CloudMoveCLI.pastCopyLimits(["ok": false, "error_code": "copy.too_large"]))
        #expect(!CloudMoveCLI.pastCopyLimits(["ok": true, "estimate": ["mode": "whole"], "estimate_bytes": 30, "needed_size": "sm"]))
        #expect(!CloudMoveCLI.pastCopyLimits(["ok": true, "estimate": ["mode": "seed", "copy_mode": "first_pass"], "estimate_bytes": 30, "needed_size": "md"]))
        #expect(!CloudMoveCLI.pastCopyLimits(["ok": true, "estimate": NSNull()]))
        #expect(!CloudMoveCLI.pastCopyLimits(["ok": false, "error_code": "usage.invalid"]))
    }

    /// The setting off, or a folder within the copy's limits: nothing is projected and no `project` runs, so the start
    /// copies exactly as before.
    @Test func offOrAFolderUnderTheLimitsCopiesAsBefore() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstPass = #"{"ok":true,"estimate":{"mode":"first_pass"},"estimate_bytes":5,"needed_size":"sm"}"#
        let mounted = #"{"ok":true,"mode":"projected","mount":"p-k-1","machine_path":"/w/big","folder":"/w/big"}"#
        let (cli, log) = try fakeCLI(in: dir, preflight: firstPass, project: mounted)
        let children = Children()
        let folders = CloudProjectedFolders(folder: nil) { children.launch($0) }
        let off = await folders.start(on: false, cli: cli, key: "k", account: "u/", machine: "vm", socket: "/s", local: "/l", subpath: "", workRoots: ["/w"], acpmuxHome: nil)
        #expect(off == nil && calls(log).isEmpty && folders.mounts.isEmpty)
        let noSocket = await folders.start(on: true, cli: cli, key: "k", account: "u/", machine: "vm", socket: nil, local: "/l", subpath: "", workRoots: ["/w"], acpmuxHome: nil)
        #expect(noSocket == nil && calls(log).isEmpty)

        let whole = #"{"ok":true,"estimate":{"mode":"whole"},"estimate_bytes":5,"needed_size":"sm"}"#
        let (small, smallLog) = try fakeCLI(in: try temporaryFolder(), preflight: whole, project: mounted)
        let under = await folders.start(on: true, cli: small, key: "k", account: "u/", machine: "vm", socket: "/s", local: "/l", subpath: "", workRoots: ["/w"], acpmuxHome: nil)
        #expect(under == nil && calls(smallLog) == ["preflight"] && folders.mounts.isEmpty && children.launched.isEmpty)
    }

    /// A folder past the limits is mounted and served, and the chat opens in the machine's path with nothing left on this
    /// Mac; a refusal (`fallback: copy`) serves nothing and the start copies.
    @Test func aBigFolderIsProjectedAndARefusalFallsBackToTheCopy() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstPass = #"{"ok":true,"estimate":{"mode":"first_pass"},"estimate_bytes":5,"needed_size":"sm"}"#
        let mounted = #"{"ok":true,"mode":"projected","mount":"p-k-1","machine_path":"/w/big/sub","folder":"/w/big","entries":3,"bytes":5,"skipped":0}"#
        let (cli, log) = try fakeCLI(in: dir, preflight: firstPass, project: mounted)
        let children = Children()
        var launches = children.launches.makeAsyncIterator()
        let folders = CloudProjectedFolders(folder: nil) { children.launch($0) }
        let started = try #require(await folders.start(on: true, cli: cli, key: "k", account: "u/", machine: "vm", socket: "/s", local: "/l", subpath: "sub", workRoots: ["/w"], acpmuxHome: nil))
        #expect(started.0.ok && started.0.leftOnMac == nil)
        #expect(started.1.chat == "/w/big/sub" && started.1.folder == "/w/big")
        #expect(calls(log) == ["preflight", "project"])
        #expect(await launches.next() == 1)
        #expect(children.launched == ["p-k-1"] && folders.record(machine: "vm", folder: "/w/big")?.mount == "p-k-1")

        let refused = #"{"ok":false,"code":"mount_failed","message":"no helper","fallback":"copy"}"#
        let (refusing, _) = try fakeCLI(in: try temporaryFolder(), preflight: firstPass, project: refused)
        let other = CloudProjectedFolders(folder: nil) { children.launch($0) }
        #expect(await other.start(on: true, cli: refusing, key: "k", account: "u/", machine: "vm", socket: "/s", local: "/l", subpath: "", workRoots: ["/w"], acpmuxHome: nil) == nil)
        #expect(other.mounts.isEmpty && children.launched == ["p-k-1"])
    }

    @Test func aServeChildThatExitsStartsAgainAfterAGrowingWait() async throws {
        let clock = ManualClock(), children = Children()
        var launches = children.launches.makeAsyncIterator()
        let folders = CloudProjectedFolders(folder: nil, clock: clock) { children.launch($0) }
        folders.serve(record("p-k-1"))
        folders.serve(record("p-k-1"))
        #expect(await launches.next() == 1)
        children.exitOnItsOwn()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        #expect(await launches.next() == 2)
        #expect(children.launched == ["p-k-1", "p-k-1"])
        // A mount id that is a path is never served.
        folders.serve(record("../x"))
        #expect(folders.mounts == ["p-k-1"])
    }

    @Test func aStoppedChildIsTerminatedAndNeverStartsAgain() async {
        let children = Children()
        var launches = children.launches.makeAsyncIterator(), stops = children.stops.makeAsyncIterator()
        let folders = CloudProjectedFolders(folder: nil) { children.launch($0) }
        folders.serve(record("p-k-1"))
        folders.serve(record("p-k-2", machine: "vm-2"))
        #expect(await launches.next() == 1)
        #expect(await launches.next() == 2)
        await folders.stop("p-k-1")
        #expect(await stops.next() == "p-k-1")
        #expect(folders.mounts == ["p-k-2"])
        // Quit: every child ends and its exit is awaited.
        await folders.stopAllAndWait()
        #expect(await stops.next() == "p-k-2")
        #expect(folders.mounts.isEmpty)
    }

    @Test func aChildWhoseRecordIsGoneSaysSo() {
        #expect(CloudProjectedFolders.recordMissing(#"{"ok":false,"code":"record_missing","message":"no","fallback":"copy"}"#))
        #expect(!CloudProjectedFolders.recordMissing(#"{"ok":false,"code":"link_failed"}"#))
        #expect(!CloudProjectedFolders.recordMissing("not json"))
    }

    /// A machine list adopts this account's records of listed machines (a launch serves again), removes the records of
    /// machines it no longer names and stops their children; another account's records stay.
    @Test func aMachineListAdoptsRecordsAndRemovesThoseOfGoneMachines() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (mount, account, machine) in [("p-a-1", "u/", "vm-1"), ("p-b-1", "u/", "vm-gone"), ("p-c-1", "other/", "vm-3")] {
            let dir = folder.appendingPathComponent(mount, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = #"{"mount":"\#(mount)","account":"\#(account)","machine":"\#(machine)","local_root":"/l","machine_path":"/w/x","folder":"/w/x","state_dir":"/w/.projfs","socket":"/s","made_at":1}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("record.json"))
        }
        let children = Children()
        var launches = children.launches.makeAsyncIterator(), stops = children.stops.makeAsyncIterator()
        let folders = CloudProjectedFolders(folder: folder) { children.launch($0) }
        folders.serve(record("p-z-1", machine: "vm-old"))
        #expect(await launches.next() == 1)
        await folders.listed(machines: ["vm-1", "vm-3"], account: "u/") { true }
        #expect(await stops.next() == "p-z-1")
        #expect(await launches.next() == 2)
        #expect(folders.mounts == ["p-a-1"] && children.launched.last == "p-a-1")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["p-a-1", "p-c-1"])
        // A list that is no longer the signed-in account's adopts nothing.
        folders.stopAll()
        await folders.listed(machines: ["vm-1"], account: "u/") { false }
        #expect(folders.mounts.isEmpty)
    }

    /// The way back: a projected folder's pull is `project-pull`, its conflicts and refusals the copy pull's
    /// `sync_conflict` naming the files; a copied folder's is the copy's own pull.
    @Test func bringingBackAProjectedFolderPullsItAndNamesItsConflicts() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pulled = #"{"ok":true,"mount":"p-k-1","applied":2,"conflicts":[{"path":"a.txt","kept":"mac","beside":"a.cloud.txt"}],"refused":[{"path":"b","reason":"symlink"}]}"#
        let (cli, log) = try fakeCLI(in: dir, preflight: "{}", pull: pulled)
        let children = Children()
        let folders = CloudProjectedFolders(folder: nil) { children.launch($0) }
        folders.serve(record("p-k-1"))
        var copied = 0
        let answer = try await folders.pull(machine: "vm-1", folder: "/w/chats/k/1/big", socket: "/s", cli: cli) { copied += 1; return .init(ok: true) }
        #expect(answer.errorCode == "sync_conflict" && answer.conflicts == ["a.txt", "b"] && copied == 0)
        #expect(calls(log) == ["project-pull"])
        let other = try await folders.pull(machine: "vm-1", folder: "/w/elsewhere", socket: "/s", cli: cli) { copied += 1; return .init(ok: true) }
        #expect(other.ok && copied == 1)
        #expect(CloudMoveCLI.StartChatProjectPull(ok: true).answer.ok)
        #expect(CloudMoveCLI.StartChatProjectPull(ok: false, code: "record_missing").answer.errorCode == "record_missing")
    }

    @Test func theRecordsFolderIsCmuxTuisStateFolders() {
        #expect(CloudProjectedFolders.recordsFolder(environment: ["CMUX_TUI_STATE_DIR": "/st"], home: "/h").path == "/st/cloud-start-chat/projected")
        #expect(CloudProjectedFolders.recordsFolder(environment: [:], home: "/h").path == "/h/Library/Application Support/cmux-tui/sessions/cloud-start-chat/projected")
    }
}
