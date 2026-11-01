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
        // ssh never reached the peer, whichever step reports it: offline, not broken (Leo's toast).
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"ssh h failed: ssh: connect to host 192.0.2.7 port 22: Operation timed out"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","error":"ssh: Could not resolve hostname h: nodename nor servname provided"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"Connection timed out during banner exchange"}"#) == .unreachable)
        // A later step whose connection failed may have changed the peer: it shows (review at 025f476).
        #expect(outcome(#"{"outcome":"failed","reason":"restartFailed","error":"Connection timed out during banner exchange"}"#) == .failed)
        #expect(outcome(#"{"outcome":"failed","reason":"noAnswer","error":"ssh h failed: ssh: connect to host 192.0.2.7 port 22: Operation timed out"}"#) == .failed)
        // The peer dropped during the binary's upload: nothing was installed (review of #27288).
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: client_loop: send disconnect: Broken pipe lost connection"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: Connection closed by 192.0.2.7 port 22"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: Connection closed"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: Read from remote host h: Connection reset by 192.0.2.7 port 22"}"#) == .unreachable)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: ssh: connect to host 192.0.2.7 port 22: Operation timed out"}"#) == .unreachable)
        // A full disk on the peer is a failure, and a dropped later step may have changed it.
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: scp: write remote: No space left on device"}"#) == .failed)
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed: scp: dest open \"/home/u/.local/bin/.acpmux-new/acpmux\": Permission denied"}"#) == .failed)
        // An older acpmux's push kept no scp words: no sign the connection dropped, so it shows.
        #expect(outcome(#"{"outcome":"failed","reason":"pushFailed","error":"scp to h failed"}"#) == .failed)
        #expect(outcome(#"{"outcome":"failed","reason":"restartFailed","error":"ssh h failed: Connection closed by 192.0.2.7 port 22"}"#) == .failed)
        // ssh reached it and something there failed: still a failure.
        #expect(outcome(#"{"outcome":"failed","reason":"restartFailed","error":"ssh h failed: Bootstrap failed: 125"}"#) == .failed)
        // The connection holding the update's lease dropped: the CLI changed nothing more, so the
        // peer is offline and asked again, not failed (review of #27288 at 1211894).
        #expect(outcome(#"{"outcome":"failed","reason":"lockLost","error":"h lost its update lock: its connection ended"}"#) == .unreachable)
        // Another update holds the host's lock: nothing changed, not now (review of #25388).
        #expect(outcome(#"{"outcome":"failed","reason":"updateRunning","error":"another update of h is running"}"#) == .busy)
        // --keep-newer left a later or own build alone.
        #expect(outcome(#"{"outcome":"current","reason":"newer","error":"h runs fedcba987 2026-10-25"}"#) == .current)
        // Held off updates (`acpmux host hold`): never reached.
        #expect(outcome(#"{"outcome":"held","ok":true,"reason":"held","error":"h is held"}"#) == .held)
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
        #expect(events.withLock { $0 } == [.updating, .offline, .updating, .updated(build: Self.local)])
        let ledger = DaemonUpdateLedger.read(state, build: try #require(DaemonBuildCommit(Self.local)).hash)
        #expect(ledger.targets == ["acpmux-peer:huge-blue": "updated"])
    }

    /// The connection holding the update's lease dropped as the binary's copy finished (`failed`,
    /// reason `lockLost`, acpmux `an_update_whose_lock_connection_drops_changes_nothing_more`): the
    /// old daemon runs on, so nothing is recorded or shown as failed, and the retry updates it.
    @Test func anUpdateWhoseLockDroppedIsAskedAgainNotRecordedFailed() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", 1, #"{"updated":[{"peer":"huge-blue","host":"huge-blue","outcome":"failed","ok":false,"build":null,"reason":"lockLost","error":"huge-blue lost its update lock: its connection ended"}],"peers":[]}"#)
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
        #expect(events.withLock { $0 } == [.updating, .offline, .updating, .updated(build: Self.local)])
        let ledger = DaemonUpdateLedger.read(state, build: try #require(DaemonBuildCommit(Self.local)).hash)
        #expect(ledger.targets == ["acpmux-peer:huge-blue": "updated"])
    }

    /// Leo's toast "Couldn't update <machine>: acpmux exited without a status": the local daemon
    /// restarted while a `host update` ran, and a signal ended the CLI before it printed a reply.
    /// That says nothing about the peer: no failure shows or is recorded, the policy asks again
    /// after its backoff, and the retry updates it.
    @Test func aRunCutShortByASignalIsAskedAgainQuietly() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.killed("huge-blue", 1)
        try fixture.killed("huge-blue", 2)
        try fixture.reply("huge-blue", 3, #"{"updated":[{"peer":"huge-blue","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let source = fixture.source(peers: ["huge-blue"])
        let reply = await source.hostUpdate("huge-blue", binaries: fixture.root, whileBusy: true)
        #expect(reply.outcome == .interrupted)

        let events = Mutex<[DaemonUpdateEvent]>([])
        let clock = PolicyTestClock()
        let state = fixture.root.appendingPathComponent("state")
        await DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true },
            report: { event in events.withLock { $0.append(event) } }, directory: state, clock: clock
        )).run()

        #expect(fixture.calls.count == 3)
        #expect(clock.sleeps == [.seconds(120)])
        #expect(events.withLock { $0.map(\.state) } == [.updating, .retrying, .updating, .updated(build: Self.local)])
        #expect(events.withLock { $0.allSatisfy { !$0.notify } }, "a notice for a run cut short")
        let ledger = DaemonUpdateLedger.read(state, build: try #require(DaemonBuildCommit(Self.local)).hash)
        #expect(ledger.targets == ["acpmux-peer:huge-blue": "updated"])
    }

    /// A peer offline when the launch looked is updated once it connects: its sessions change on
    /// the app's watch (``AcpmuxPeerReconnects``), one status read finds it connected and the shared
    /// queue updates it. Later changes read nothing; a drop and a reconnect offer it again, and the
    /// ledger keeps that to one update per build.
    @Test @MainActor func aPeerThatConnectsLaterIsUpdated() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"updated":[{"peer":"huge-blue","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let connected = Mutex(false)
        let reads = Mutex(0)
        let source = fixture.source(peers: [], status: {
            reads.withLock { $0 += 1 }
            return AcpmuxPeerUpdateStatus(build: Self.local, peers: [Self.peer("huge-blue", connected: connected.withLock { $0 }),
                                                                     Self.peer("websocket", url: "ws://10.0.0.2:47811")])
        })
        let policy = DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: fixture.root.appendingPathComponent("state"), clock: PolicyTestClock()))
        let reconnects = AcpmuxPeerReconnects(offer: { await policy.offer($0) }, enabled: { true })
        #expect(reconnects.note(peer: "huge-blue", stale: false) == nil, "nothing before the launch's discovery arms it")
        reconnects.source = source
        await policy.run()
        #expect(fixture.calls.isEmpty, "offline at launch")

        // Its cached rows change while it is still down: one read, nothing offered.
        let before = reads.withLock { $0 }
        await reconnects.note(peer: "huge-blue", stale: false)?.value
        #expect(reads.withLock { $0 } == before + 1)
        #expect(fixture.calls.isEmpty)

        connected.withLock { $0 = true }
        await reconnects.note(peer: "huge-blue", stale: false)?.value
        await policy.drained()
        #expect(fixture.calls.count == 1, "updated once it connected")
        #expect(reconnects.note(peer: "huge-blue", stale: false) == nil, "more changes while connected read nothing")
        await reconnects.note(peer: "websocket", stale: false)?.value
        #expect(reconnects.note(peer: "websocket", stale: false) == nil, "not an ssh peer: read once, never offered")

        #expect(reconnects.note(peer: "huge-blue", stale: true) == nil)
        await reconnects.note(peer: "huge-blue", stale: false)?.value
        await policy.drained()
        #expect(fixture.calls.count == 1, "offered again after a reconnect; the ledger has it updated on this build")
    }

    /// Review of #24070: a peer that connects with no session sends no change on the app's watch,
    /// so only the next launch updated it. The sweep offers it at its next read; turning
    /// `agent.updatePeers` off ends the sweep.
    /// Review of #25389: a DEV build attached to another app's daemon (`CMUX_NEXT_ACPMUX_ATTACH`)
    /// updates no peers; that daemon's owner does. Builds that ignore the variable still update.
    @Test func anAppAttachedToAnotherDaemonUpdatesNoPeers() {
        let dev = BuildIdentity(bundleID: "com.cmuxterm.app.debug.peers", bundledTag: nil)
        let attached = [AcpmuxEnvironment.attachKey: "/tmp/another-app/.acpmux"]
        #expect(!DaemonUpdatePolicy.updatesPeers(build: dev, environment: attached))
        #expect(DaemonUpdatePolicy.updatesPeers(build: dev, environment: [:]))
        let nightly = BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil)
        #expect(DaemonUpdatePolicy.updatesPeers(build: nightly, environment: attached), "only DEV builds attach")
    }

    /// Review of #25389: the live source's bundled `--version` probe is bounded, so the launch
    /// offer, a reconnect check and the sweep never wait on a CLI that does not answer.
    @Test(.timeLimit(.minutes(1))) func theLiveSourcesBundledVersionEndsAtItsBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-peer-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let acpmux = try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: nil, environment: ["ACPMUX_HOME": root.path],
                                                            executableOverride: script, teamIdentifier: nil))
        let source = AcpmuxPeerUpdateSource.live(acpmux, directory: root, versionBound: .milliseconds(500)) { _, _ in
            throw CancellationError()
        }

        let started = ContinuousClock.now
        #expect(await source.bundledBuild() == nil)
        #expect(ContinuousClock.now - started < .seconds(20), "the probe ended at its bound")
    }

    @Test @MainActor func aPeerThatConnectsWithNoSessionIsUpdatedByTheSweep() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        try fixture.reply("huge-blue", nil, #"{"updated":[{"peer":"huge-blue","outcome":"updated","ok":true,"build":"abc123def 2026-10-20"}],"peers":[]}"#)
        let connected = Mutex(false)
        let source = fixture.source(peers: [], status: {
            AcpmuxPeerUpdateStatus(build: Self.local, peers: [Self.peer("huge-blue", connected: connected.withLock { $0 })])
        })
        let policy = DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true }, report: { _ in },
            directory: fixture.root.appendingPathComponent("state"), clock: PolicyTestClock()))
        // On for three sweeps; the peer connects after the first.
        let sweeps = Mutex(0)
        let reconnects = AcpmuxPeerReconnects(offer: { target in
            await policy.offer(target)
            await policy.drained()
        }, enabled: {
            sweeps.withLock { count in
                defer { count += 1 }
                if count == 1 { connected.withLock { $0 = true } }
                return count < 3
            }
        })
        await policy.run()
        #expect(fixture.calls.isEmpty, "offline at launch")

        await reconnects.sweep(source, every: .seconds(600), clock: PolicyTestClock()).value
        #expect(fixture.calls.count == 1, "updated at the sweep after it connected, once")
        #expect(sweeps.withLock { $0 } == 4, "the sweep ended when the toggle read off")
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

    /// A machine held off updates (`acpmux host hold`, such as one reserved for someone else): the
    /// CLI answers `held` without reaching it. Nothing is recorded, no failure shows, and the
    /// queue does not ask again in this run, also when the peer is offered again (the sweep, a
    /// reconnect). The queue's log names the hold with the daemon's reason and `until`, not
    /// `handledElsewhere` (nightly 1.0.0-nightly.4048947256901 logged
    /// `hbnv-held to 52b77ef2f while busy: handledElsewhere`).
    @Test func aHeldPeerShowsNoFailureAndIsNotRecorded() async throws {
        let fixture = try StandInAcpmux()
        defer { fixture.remove() }
        let why = "mini-a is held (reserved for a teammate) until 2026-10-28T23:59:59Z, so host update leaves it alone (`acpmux host hold mini-a --release` ends it)"
        try fixture.reply("mini-a", nil, #"{"updated":[{"peer":"mini-a","host":"mini-a","outcome":"held","ok":true,"build":null,"reason":"held","error":"\#(why)"}],"peers":[]}"#)
        let source = fixture.source(peers: ["mini-a"])
        let events = Mutex<[DaemonUpdateEvent]>([])
        let state = fixture.root.appendingPathComponent("state")
        let policy = DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { Self.local }, targets: { await source.targets() }, enabled: { true },
            report: { event in events.withLock { $0.append(event) } }, directory: state, clock: PolicyTestClock()
        ))
        await policy.run()
        for target in await source.targets() { await policy.offer(target) }
        await policy.drained()

        #expect(fixture.calls.count == 1)
        #expect(events.withLock { $0.map(\.state) } == [.updating, .cleared])
        #expect(!events.withLock { $0.contains { $0.notify } })
        let local = try #require(DaemonBuildCommit(Self.local))
        let ledger = DaemonUpdateLedger.read(state, build: local.hash)
        #expect(ledger.targets.isEmpty)

        let targets = await source.targets()
        let target = try #require(targets.first)
        let outcome = await target.update(to: local, whileBusy: true)
        #expect(outcome == .held(reason: why))
        #expect(DaemonUpdatePolicy.logLine("mini-a", to: local.hash, whileBusy: true, outcome) == "mini-a to abc123def while busy: held (\(why))")
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
        // Leo, 2026-10-29: "...deadline and was stopped; it exited" ended on nothing. A confirmed
        // exit ends the line at "was stopped"; only a child that outlived SIGKILL says more.
        #expect(result.errors.hasSuffix("was stopped"), "\(result.errors)")
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
        if [ -f "$dir/replies/$4.$n.killed" ]; then rmdir "$dir/running"; kill -KILL $$; fi
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

    /// The peer's `run`-th run ends by SIGKILL before it prints anything.
    func killed(_ peer: String, _ run: Int) throws {
        try Data().write(to: root.appendingPathComponent("replies/\(peer).\(run).killed"))
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
