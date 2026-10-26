import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The acpmux ssh peer as a ``DaemonUpdateTarget``: which peers are targets, how the CLI's reply
/// reads, and `host update` against a stand-in `acpmux` that logs its arguments and prints canned
/// replies. No real peer or daemon is touched.
@Suite nonisolated struct AcpmuxPeerUpdateTargetTests {
    static let local = "abc123def 2026-10-20"
    static let older = "0123456ff 2026-10-01"
    static let triple = "x86_64-unknown-linux-musl"

    static func peer(_ name: String, _ build: String? = older, connected: Bool = true, url: String? = nil) -> AcpmuxPeerUpdateStatus.Peer {
        AcpmuxPeerUpdateStatus.Peer(name: name, url: url ?? "ssh://\(name)", connected: connected, remoteBuild: build)
    }

    // MARK: Which peers

    @Test func onlyConnectedSSHPeersAreTargets() {
        let status = AcpmuxPeerUpdateStatus(build: Self.local, peers: [
            Self.peer("offline", connected: false),
            Self.peer("websocket", url: "ws://10.0.0.2:47811"),
            Self.peer("-flag"),
            Self.peer("cmux16"),
        ])
        #expect(status.updatablePeers.map(\.name) == ["cmux16"])
    }

    @Test func aDirtyLocalDaemonOrOneNotYetOnTheBundledBuildPushesNothing() {
        let dirty = "abc123def+dirty.1234abcd 2026-10-20"
        #expect(AcpmuxPeerUpdateStatus(build: dirty, peers: []).blocked(bundledBuild: dirty) != nil)
        #expect(AcpmuxPeerUpdateStatus(build: Self.older, peers: []).blocked(bundledBuild: Self.local) != nil)
        #expect(AcpmuxPeerUpdateStatus(build: Self.local, peers: []).blocked(bundledBuild: nil) != nil)
        #expect(AcpmuxPeerUpdateStatus(build: nil, peers: []).blocked(bundledBuild: Self.local) != nil)
        #expect(AcpmuxPeerUpdateStatus(build: Self.local, peers: []).blocked(bundledBuild: Self.local) == nil)
    }

    @Test func statusReadsPeersAndIgnoresUnknownFields() {
        let status = AcpmuxPeerUpdateStatus([
            "build": Self.local, "home": "/tmp/h", "webUrl": "ws://x",
            "peers": [
                ["name": "huge-blue", "url": "ssh://huge-blue", "connected": true, "remoteBuild": Self.older,
                 "localBuild": Self.local, "outdated": true, "state": "up"],
                ["url": "ssh://nameless", "connected": true],
            ],
        ])
        #expect(status.build == Self.local && status.home == "/tmp/h")
        #expect(status.peers == [Self.peer("huge-blue")])
    }

    @Test func sshHostComesFromThePeerURL() {
        #expect(AcpmuxPeerUpdateStatus.host(ofURL: "ssh://huge-blue") == "huge-blue")
        #expect(AcpmuxPeerUpdateStatus.host(ofURL: "ssh://leo@Huge-Blue:2222/") == "huge-blue")
        #expect(AcpmuxPeerUpdateStatus.host(ofURL: "ssh://[fd7a::1]:22") == "fd7a::1")
        #expect(AcpmuxPeerUpdateStatus.host(ofURL: "ws://huge-blue:47811") == nil)
    }

    // MARK: Reply

    @Test func replyParsesEveryOutcome() {
        func outcome(_ json: String) -> AcpmuxPeerUpdateReply.Outcome? { AcpmuxPeerUpdateReply.parse(json)?.outcome }
        #expect(outcome(#"{"outcome":"updated","build":"abc123def 2026-10-20","migratedFrom":"0123456ff 2026-10-01"}"#) == .updated)
        #expect(outcome(#"{"outcome":"current"}"#) == .current)
        #expect(outcome(#"{"outcome":"busy","sessions":3}"#) == .busy)
        #expect(outcome(#"{"outcome":"needsBinary","target":"x86_64-unknown-linux-musl"}"#) == .needsBinary(target: Self.triple))
        #expect(outcome(#"{"outcome":"rolledBack","error":"daemon did not come up"}"#) == .rolledBack)
        #expect(outcome(#"{"outcome":"failed","error":"ssh: connection refused"}"#) == .failed)
        #expect(outcome(#"{"outcome":"failed","reason":"cloudMachine","error":"a cmux Cloud VM"}"#) == .cloudMachine)
        #expect(outcome(#"{"outcome":"failed","reason":"unreachable","error":"ssh huge-blue failed: timed out"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp failed"}"#) == .failed)
        // Another update holds the host's lock: nothing changed, not now (review of #25388).
        #expect(outcome(#"{"outcome":"failed","reason":"updateRunning","error":"another update of h is running"}"#) == .busy)
        // --keep-newer left a later or own build alone.
        #expect(outcome(#"{"outcome":"current","reason":"newer","error":"h runs fedcba987 2026-10-25"}"#) == .current)
        #expect(outcome(#"{"outcome":"somethingNew"}"#) == .failed)
        // A target names a file in the binary directory: anything but a plain triple fails.
        #expect(outcome(#"{"outcome":"needsBinary","target":"../../etc/passwd"}"#) == .failed)
        #expect(outcome(#"{"outcome":"needsBinary"}"#) == .failed)
        #expect(outcome("not json") == nil)
        #expect(outcome(#"{"name":"huge-blue"}"#) == nil)
    }

    @Test func replyKeepsItsDetailsAndSkipsLinesBeforeIt() throws {
        let reply = try #require(AcpmuxPeerUpdateReply.parse("""
        uploading acpmux to huge-blue
        {"name":"huge-blue","outcome":"updated","build":"abc123def 2026-10-20","migratedFrom":"0123456ff 2026-10-01","extra":{"a":1}}
        """))
        #expect(reply == AcpmuxPeerUpdateReply(outcome: .updated, build: Self.local, migratedFrom: Self.older))
    }

    /// The CLI's own shape (acpmux `cli/hosts.rs` `update`): rows under `updated`, one per peer.
    @Test func replyReadsTheCLIsRowForThePeer() throws {
        let output = """
        {"updated": [
          {"peer": "cmux16", "host": "cmux16", "outcome": "busy", "ok": true, "build": null, "reason": "busy", "error": "a turn runs"},
          {"peer": "huge-blue", "host": "huge-blue", "outcome": "updated", "ok": true, "build": "d5829ffea 2026-10-21",
           "target": "x86_64-unknown-linux-musl", "version": "acpmux 1.0.0 (d5829ffea 2026-10-21)", "status": "{}",
           "migratedFrom": "acpmux-agent-huge-blue.service"}
        ], "peers": [{"name": "huge-blue"}]}
        """
        let reply = try #require(AcpmuxPeerUpdateReply.parse(output, peer: "huge-blue"))
        #expect(reply == AcpmuxPeerUpdateReply(outcome: .updated, build: "d5829ffea 2026-10-21", migratedFrom: "acpmux-agent-huge-blue.service"))
        #expect(AcpmuxPeerUpdateReply.parse(output, peer: "cmux16")?.outcome == .busy)
        #expect(AcpmuxPeerUpdateReply.parse(output, peer: "elsewhere") == nil)
        let single = #"{"updated": [{"peer": "x", "outcome": "rolledBack", "ok": false, "build": null, "error": "buildMismatch"}], "peers": []}"#
        #expect(AcpmuxPeerUpdateReply.parse(single, peer: "y")?.outcome == .rolledBack)
    }

    // MARK: host update

    @Test func needsBinaryDownloadsStagesAndRunsAgain() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("cmux16", 1, #"{"updated":[{"peer":"cmux16","outcome":"needsBinary","ok":true,"build":null,"target":"x86_64-unknown-linux-musl","reason":"noBinary"}],"peers":[]}"#)
        try fixture.reply("cmux16", 2, #"{"updated":[{"peer":"cmux16","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let targets = await fixture.source(peers: ["cmux16"]).targets()
        let target = try #require(targets.first)
        #expect(target.id == "acpmux-peer:cmux16" && target.sshHost == "cmux16")
        #expect(await target.currentBuild() == Self.older)

        let local = try #require(DaemonBuildCommit(Self.local))
        let outcome = await target.update(to: local, whileBusy: false)
        #expect(outcome == .updated(build: Self.local))
        try #require(fixture.calls.count == 2)
        #expect(fixture.calls[0].staged.isEmpty)
        #expect(fixture.calls[1].staged == ["acpmux-\(Self.triple)"])
        #expect(fixture.downloads == ["cmux-tui-acpmux-\(Self.triple)"])
        let staged = try #require(fixture.calls[1].binaryDirectory).appendingPathComponent("acpmux-\(Self.triple)")
        #expect(FileManager.default.isExecutableFile(atPath: staged.path))
    }

    @Test func aBinaryThatCannotBeDownloadedIsNeedsBinary() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("cmux16", nil, #"{"outcome":"needsBinary","target":"aarch64-unknown-linux-musl"}"#)
        let targets = await fixture.source(peers: ["cmux16"], downloadFails: true).targets()
        let target = try #require(targets.first)
        let local = try #require(DaemonBuildCommit(Self.local))
        #expect(await target.update(to: local, whileBusy: false) == .needsBinary(target: "aarch64-unknown-linux-musl"))
        #expect(fixture.calls.count == 1)
    }

    @Test func rollbackAndFailureCarryTheCLIsReason() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"outcome":"rolledBack","error":"new daemon reported 0123456ff"}"#)
        try fixture.reply("cmux16", nil, #"{"outcome":"failed","error":"ssh exited 255"}"#)
        let targets = await fixture.source(peers: ["huge-blue", "cmux16"]).targets()
        let local = try #require(DaemonBuildCommit(Self.local))
        try #require(targets.count == 2)
        #expect(await targets[0].update(to: local, whileBusy: false) == .rolledBack(reason: "new daemon reported 0123456ff"))
        #expect(await targets[1].update(to: local, whileBusy: false) == .failed(reason: "ssh exited 255"))
    }

    /// The production default (Leo: "OUR SHIT IS HARDLY EVER GOING TO GO IDLE ... IT RESUMES
    /// WHATEVER IT INTERRUPTED"): through the policy, the first `host update` already drops
    /// `--if-idle`, so a peer where an agent works is updated mid-turn at once.
    @Test func theFirstHostUpdateDropsIfIdle() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"outcome":"updated","build":"abc123def 2026-10-20"}"#)
        let source = fixture.source(peers: ["huge-blue"])
        await DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: fixture.root.appendingPathComponent("state"), clock: PolicyTestClock()
        )).run()

        try #require(fixture.calls.count == 1)
        let binaries = try #require(fixture.calls.first?.binaryDirectory)
        let busy = AcpmuxPeerUpdateCommand.updateArguments(peer: "huge-blue", binaryDirectory: binaries, whileBusy: true)
        #expect(fixture.calls.map(\.arguments) == [busy])
    }

    /// A peer whose own `acpmux-update.timer` (#24232) already moved it to a newer feat-cmux-next
    /// build is never moved back: no `host update` runs.
    @Test func aPeerOnANewerBuildIsNotMovedBack() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"outcome":"updated","build":"abc123def 2026-10-20"}"#)
        let source = fixture.source(peers: [], status: {
            AcpmuxPeerUpdateStatus(build: Self.local, peers: [Self.peer("huge-blue", "fedcba987 2026-10-25")])
        })
        await DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: fixture.root.appendingPathComponent("state"), clock: PolicyTestClock()
        )).run()
        #expect(fixture.calls.isEmpty)
    }

    /// With the optional busy cap (`updateBusyAfter`, zero by default) of 10 minutes: huge-blue
    /// never has an idle moment, so through the policy `host update` carries `--if-idle` (at 0, 2
    /// and 6 minutes) until the peer has been busy for the cap, then runs once without it and
    /// restarts the daemon mid-turn.
    @Test func withACapHostUpdatesCarryIfIdleUntilIt() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"outcome":"busy"}"#)
        try fixture.reply("huge-blue", 4, #"{"outcome":"updated","build":"abc123def 2026-10-20"}"#)
        let source = fixture.source(peers: ["huge-blue"])
        for target in await source.targets() {
            #expect(await target.urgent == false, "an acpmux peer is never urgent")
        }
        var dependencies = DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: fixture.root.appendingPathComponent("state"), clock: PolicyTestClock()
        )
        dependencies.updateBusyAfter = .seconds(600)
        await DaemonUpdatePolicy(dependencies).run()

        try #require(fixture.calls.count == 4)
        let binaries = try #require(fixture.calls.first?.binaryDirectory)
        let idle = AcpmuxPeerUpdateCommand.updateArguments(peer: "huge-blue", binaryDirectory: binaries, whileBusy: false)
        let busy = AcpmuxPeerUpdateCommand.updateArguments(peer: "huge-blue", binaryDirectory: binaries, whileBusy: true)
        #expect(fixture.calls.map(\.arguments) == [idle, idle, idle, busy])
        #expect(!fixture.overlapped)
    }

    /// The peer dropped off the network after the app read its build: the CLI's ssh probe fails
    /// (`failed`, reason `unreachable`, acpmux `cli/host_update.rs`). That is no failure of this
    /// build: nothing is recorded or shown as failed, the policy asks again after its backoff, and
    /// the peer, back on the network, is updated.
    @Test func anUnreachablePeerIsAskedAgainNotRecordedFailed() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", 1, #"{"updated":[{"peer":"huge-blue","host":"huge-blue","outcome":"failed","ok":false,"build":null,"reason":"unreachable","error":"ssh huge-blue failed: Connection timed out"}],"peers":[]}"#)
        try fixture.reply("huge-blue", 2, #"{"updated":[{"peer":"huge-blue","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let source = fixture.source(peers: ["huge-blue"])
        let events = Mutex<[DaemonUpdateEvent.State]>([])
        let clock = PolicyTestClock()
        let state = fixture.root.appendingPathComponent("state")
        await DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true },
            report: { event in events.withLock { $0.append(event.state) } }, directory: state, clock: clock
        )).run()

        #expect(fixture.calls.count == 2)
        #expect(clock.sleeps == [.seconds(120)])
        #expect(events.withLock { $0 } == [.updating, .retrying, .updating, .updated(build: Self.local)])
        let ledger = DaemonUpdateLedger.read(state, build: try #require(DaemonBuildCommit(Self.local)).hash)
        #expect(ledger.targets == ["acpmux-peer:huge-blue": "updated"])
    }

    /// Every run carries `--keep-newer` (#25425): the CLI, under the host's update lock, leaves a
    /// peer alone that a self-update moved past the pushed build after the app read it (review of
    /// #25388). `--if-idle` only when the queue asks idle.
    @Test func updateArgumentsKeepNewerAndDropIfIdleOnlyWhileBusy() {
        let binaries = URL(fileURLWithPath: "/tmp/binaries/abc123def")
        let base = ["--json", "host", "update", "cmux16", "--binary-dir", "/tmp/binaries/abc123def", "--keep-newer"]
        #expect(AcpmuxPeerUpdateCommand.updateArguments(peer: "cmux16", binaryDirectory: binaries, whileBusy: false) == base + ["--if-idle"])
        #expect(AcpmuxPeerUpdateCommand.updateArguments(peer: "cmux16", binaryDirectory: binaries, whileBusy: true) == base)
    }

    /// Review of #25388: another update holds the host's lock (`failed`, reason `updateRunning`).
    /// That is no failure of this build: the policy asks again after its backoff and updates.
    @Test func aPeerWhoseUpdateLockIsHeldIsAskedAgain() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", 1, #"{"updated":[{"peer":"huge-blue","outcome":"failed","ok":false,"build":null,"reason":"updateRunning","error":"another update of huge-blue is running"}],"peers":[]}"#)
        try fixture.reply("huge-blue", 2, #"{"updated":[{"peer":"huge-blue","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let source = fixture.source(peers: ["huge-blue"])
        let clock = PolicyTestClock()
        let state = fixture.root.appendingPathComponent("state")
        await DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: state, clock: clock
        )).run()

        #expect(fixture.calls.count == 2)
        #expect(clock.sleeps == [.seconds(120)])
        let ledger = DaemonUpdateLedger.read(state, build: try #require(DaemonBuildCommit(Self.local)).hash)
        #expect(ledger.targets == ["acpmux-peer:huge-blue": "updated"])
    }

    /// Review of #25388: a CLI run past its deadline that ignores SIGTERM gets SIGKILL, and the
    /// run returns only once it is gone, so the queue never moves on with it still running.
    @Test(.timeLimit(.minutes(1))) func aRunPastItsDeadlineEndsItsChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-peer-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let script = root.appendingPathComponent("acpmux")
        try "#!/bin/sh\necho $$ > \(StandInAcpmux.quoted(pidFile.path))\ntrap '' TERM\nexec sleep 60\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let command = AcpmuxPeerUpdateCommand(executable: script, environment: ["PATH": "/usr/bin:/bin"],
                                              deadline: .milliseconds(500), killGrace: .seconds(1))

        let started = ContinuousClock.now
        let result = await command.run(["--json"])
        #expect(result.status == nil)
        #expect(ContinuousClock.now - started < .seconds(20))
        let pid = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!Self.runs(pid), "the child that ignored SIGTERM still runs after the run returned")
        #expect(result.errors.contains("it exited"), "the run confirmed the exit: \(result.errors)")
    }

    /// Review of #25388: the exit is confirmed by the kernel's exit event armed at the launch, and a
    /// child that has not exited holds the wait only up to its bound.
    @Test(.timeLimit(.minutes(1))) func anExitWatchWaitsForItsChildUpToItsBound() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let exit = AcpmuxChildExit()
        exit.arm(child.processIdentifier)
        defer { exit.disarm() }

        let started = ContinuousClock.now
        #expect(await exit.exited(within: .milliseconds(300)) == false, "a running child is not reported gone")
        #expect(ContinuousClock.now - started < .seconds(10), "the wait ended at its bound")
        kill(child.processIdentifier, SIGKILL)
        #expect(await exit.exited(within: .seconds(20)), "the exit event ends the wait")
        #expect(await exit.exited(within: .milliseconds(1)), "an exit seen once stays seen")
    }

    /// Whether `pid` is a live process (a zombie waiting to be reaped is not).
    static func runs(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }
}

/// A temporary directory with a stand-in `acpmux`. The script logs each run's arguments and the
/// files staged in its `--binary-dir`, marks overlapping runs, and prints `replies/<peer>.<n>`
/// for the peer's n-th run (else `replies/<peer>`).
nonisolated private final class StandInAcpmux: Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var staged: [String]
        var binaryDirectory: URL? {
            arguments.firstIndex(of: "--binary-dir").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        }
    }

    let root: URL
    private let downloadLog = Mutex<[String]>([])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-peer-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("replies"), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        dir=\(Self.quoted(root.path))
        mkdir "$dir/running" 2>/dev/null || touch "$dir/overlap"
        n=$(grep -c "^--json host update $4 " "$dir/calls.log" 2>/dev/null)
        n=$((n + 1))
        staged=$(ls "$6" 2>/dev/null | tr '\\n' ' ')
        printf '%s\\t%s\\n' "$*" "$staged" >> "$dir/calls.log"
        sleep 0.05
        if [ -f "$dir/replies/$4.$n" ]; then cat "$dir/replies/$4.$n"; else cat "$dir/replies/$4"; fi
        rmdir "$dir/running"
        """
        let acpmux = root.appendingPathComponent("acpmux")
        try script.write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func reply(_ peer: String, _ run: Int?, _ json: String) throws {
        let name = run.map { "\(peer).\($0)" } ?? peer
        try json.write(to: root.appendingPathComponent("replies/\(name)"), atomically: true, encoding: .utf8)
    }

    var calls: [Call] {
        let text = (try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            return Call(arguments: parts[0].split(separator: " ").map(String.init),
                        staged: parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : [])
        }
    }

    var overlapped: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap").path) }
    var downloads: [String] { downloadLog.withLock { $0 } }

    /// The acpmux side with this stand-in CLI and a local daemon on ``AcpmuxPeerUpdateTargetTests/local``
    /// whose `peers` are connected ssh peers on an older build; `status`, when given, is the
    /// local daemon's status instead.
    func source(peers: [String], downloadFails: Bool = false,
                status read: (@Sendable () async -> AcpmuxPeerUpdateStatus?)? = nil) -> AcpmuxPeerUpdateSource {
        let local = AcpmuxPeerUpdateTargetTests.local
        let status = AcpmuxPeerUpdateStatus(build: local, peers: peers.map { AcpmuxPeerUpdateTargetTests.peer($0) })
        let root = root
        let commit = (DaemonBuildCommit(local)?.hash ?? "") + String(repeating: "0", count: 31)
        return AcpmuxPeerUpdateSource(
            status: read ?? { status },
            bundledBuild: { local },
            command: AcpmuxPeerUpdateCommand(executable: root.appendingPathComponent("acpmux"),
                                             environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(30)),
            download: { [self] artifact in
                downloadLog.withLock { $0.append(artifact) }
                if downloadFails { throw CocoaError(.fileNoSuchFile) }
                let file = root.appendingPathComponent("download-\(artifact)")
                try Data("binary".utf8).write(to: file)
                return (file, commit)
            },
            directory: root.appendingPathComponent("state", isDirectory: true),
            clock: PolicyTestClock()
        )
    }
}
