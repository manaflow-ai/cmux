import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextRemote
@testable import CmuxNextServer
import Foundation
import Testing

/// Add Machine's runs (plans/cmux-next/add-machine-DESIGN.md): the CLI's lines reach the card as
/// they arrive, a run ends ready or failed, a failed install step runs the app's own install and
/// enroll again, Check Machine runs doctor and Fix runs `--fix`, a picked agent peer is connected
/// and checked without an enroll, and a destination from outside only fills the card. The card's
/// checklist, buttons and badges are the page's (webviews/test/server-cards-add-machine-*.test.ts).
@MainActor @Suite(.serialized) struct AddMachineFlowTests {
    // MARK: - Fixtures

    /// Fixture CLI: each run hands out the next script of lines, in order, through a stream the test
    /// feeds (no process).
    final class FakeHost {
        var scripts: [[String]] = []
        var stops: [(any Error)?] = []
        var commands: [HostCommand] = []
        var installs: [String] = []
        var names: [String] = []
        var installAnswer: AddMachineServices.Installed = .installed(machineID: "ssh-installed")
        var connected: [String] = []
        var recorded: [(String, HostReport)] = []
        var opened: [String] = []
        var copied: [String] = []
        var candidates: [HostCandidate]? = []
        /// The `probe` flag of each candidates run, in order.
        var probes: [Bool] = []
        /// One answer per candidates run, in order, before falling back to ``candidates``.
        var candidateAnswers: [[HostCandidate]?] = []
        /// Streams the test drives by hand (``feed(_:)``), when set.
        var live: AsyncThrowingStream<String, any Error>.Continuation?
        var termination: CheckedContinuation<Void, Never>?
        var holdNextRun = false
        var connectFails = false

        func services() -> AddMachineServices {
            AddMachineServices(
                parse: { text in
                    let text = text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, !text.contains(" "), !text.contains(":"), !text.hasPrefix("-") else { return nil }
                    let host = text.split(separator: "@").last.map(String.init) ?? text
                    return HostDestination(host: text, shortName: host.split(separator: ".").first.map(String.init) ?? host)
                },
                candidates: { [self] probe in
                    probes.append(probe)
                    return candidateAnswers.isEmpty ? candidates : candidateAnswers.removeFirst()
                },
                run: { [self] command in
                    commands.append(command)
                    if holdNextRun {
                        holdNextRun = false
                        return AsyncThrowingStream { continuation in
                            self.live = continuation
                            continuation.onTermination = { @Sendable _ in
                                Task { @MainActor in
                                    self.termination?.resume()
                                    self.termination = nil
                                }
                            }
                        }
                    }
                    let lines = scripts.isEmpty ? [] : scripts.removeFirst()
                    let stop = stops.isEmpty ? nil : stops.removeFirst()
                    return AsyncThrowingStream { continuation in
                        for line in lines { continuation.yield(line) }
                        continuation.finish(throwing: stop)
                    }
                },
                install: { [self] host, name in installs.append(host); names.append(name); return installAnswer },
                connect: { [self] host, name in connected.append(host); names.append(name); return connectFails ? nil : "ssh-\(host)" },
                record: { [self] id, report in recorded.append((id, report)) },
                openWorkspace: { [self] id in opened.append(id) },
                copy: { [self] text in copied.append(text) })
        }
    }

    static func step(_ step: String, _ state: String, _ detail: String = "", fix: String? = nil, reason: String? = nil) -> String {
        let fixJSON = fix.map { "\"\($0)\"" } ?? "null"
        let reasonJSON = reason.map { ",\"reason\":\"\($0)\"" } ?? ""
        return "{\"step\":\"\(step)\",\"state\":\"\(state)\",\"detail\":\"\(detail)\",\"fix\":\(fixJSON)\(reasonJSON)}"
    }

    static func report(_ name: String, _ host: String, ok: Bool, _ steps: [String]) -> String {
        "{\"report\":{\"name\":\"\(name)\",\"host\":\"\(host)\",\"ok\":\(ok),\"steps\":[\(steps.joined(separator: ","))]}}"
    }

    static let okSteps = ["reach", "install", "daemon", "update", "harness", "peer", "peer-back", "identity", "approvals"].map { step($0, "ok") }

    let host = FakeHost()
    let runs: AddMachineRuns

    init() {
        _ = NSApplication.shared
        runs = AddMachineRuns(services: host.services())
    }

    /// What the card's checklist reads of a run: the stop details and whether the install ran.
    var stops: [String] { runs.run?.events.compactMap { if case let .stop(detail) = $0 { detail } else { nil } } ?? [] }
    var outcome: AddMachineRuns.Outcome? { runs.run?.outcome }

    // MARK: - Parsing

    @Test func stepLinesParseIntoResults() throws {
        let line = Self.step("peer-back", "warn", "no route back", fix: "add a key on the host")
        #expect(HostLine.parse(line) == .step(HostStepResult(step: .peerBack, state: .warn, detail: "no route back", fix: "add a key on the host")))
        #expect(HostLine.parse(Self.step("reach", "ok")) == .step(HostStepResult(step: .reach, state: .ok)))
        // An empty fix is no fix.
        #expect(HostLine.parse("{\"step\":\"daemon\",\"state\":\"fixed\",\"detail\":\"started\",\"fix\":\"\"}")
            == .step(HostStepResult(step: .daemon, state: .fixed, detail: "started")))
    }

    @Test func theReportLineParsesWithItsSteps() throws {
        let line = Self.report("hb", "huge-blue", ok: false, [Self.step("reach", "ok"), Self.step("daemon", "fail", "no answer", fix: "start it")])
        guard case let .report(report)? = HostLine.parse(line) else { Issue.record("not a report"); return }
        #expect(report.name == "hb" && report.host == "huge-blue" && !report.ok)
        #expect(report.steps.map(\.step) == [.reach, .daemon])
        #expect(report.worstStep?.step == .daemon)
        #expect(report.health == .failing)
    }

    @Test func noiseLinesAreIgnored() {
        #expect(HostLine.parse("") == nil)
        #expect(HostLine.parse("connecting to huge-blue…") == nil)
        #expect(HostLine.parse("{\"event\":\"progress\"}") == nil)
        #expect(HostLine.parse("{\"step\":\"reach\"") == nil)
    }

    @Test func anUnknownStateReadsAsAWarning() {
        #expect(HostLine.parse(Self.step("reach", "maybe")) == .step(HostStepResult(step: .reach, state: .warn)))
    }

    @Test func healthIgnoresSkipAndCountsWarnings() {
        let warn = HostReport(name: "hb", host: "hb", ok: true, steps: [HostStepResult(step: .reach, state: .ok),
                                                                         HostStepResult(step: .peerBack, state: .warn),
                                                                         HostStepResult(step: .identity, state: .skip)])
        #expect(warn.health == .warning)
        #expect(warn.worstStep?.step == .peerBack)
        let ok = HostReport(name: "hb", host: "hb", ok: true, steps: [HostStepResult(step: .reach, state: .fixed)])
        #expect(ok.health == .ok && ok.worstStep == nil)
    }

    // MARK: - Runs

    @Test func addRunsEnrollAndEndsReady() async {
        host.scripts = [Self.okSteps + [Self.report("huge-blue", "leo@huge-blue.ts.net", ok: true, Self.okSteps)]]
        runs.begin()
        #expect(runs.run == nil, "the fields first")
        runs.add(destination: "leo@huge-blue.ts.net", name: "")
        #expect(outcome == .running)
        #expect(await runs.finished() == nil)
        #expect(host.commands == [.enroll(host: "leo@huge-blue.ts.net", name: "huge-blue")])
        #expect(outcome == .ready)
        #expect(runs.run?.name == "huge-blue")
        #expect(runs.run?.destination == "leo@huge-blue.ts.net" && runs.run?.peer == nil, "Try Again sends this again")
        #expect(runs.run?.events.first == .start(joined: false))
        #expect(runs.run?.events.count == 1 + Self.okSteps.count + 1, "every line reaches the card")
        // Not connected by an install: the add connects it, records its health, and Open Workspace opens on it.
        #expect(host.connected == ["leo@huge-blue.ts.net"])
        #expect(host.recorded.map(\.0) == ["ssh-leo@huge-blue.ts.net"])
        #expect(runs.run?.machineID == "ssh-leo@huge-blue.ts.net")
        runs.openWorkspace()
        #expect(host.opened == ["ssh-leo@huge-blue.ts.net"])
    }

    @Test func openWorkspaceFromTheCardTakesOnlyThePersonsOwnClick() async throws {
        host.scripts = [[Self.report("huge-blue", "leo@huge-blue.ts.net", ok: true, Self.okSteps)]]
        runs.begin()
        runs.add(destination: "leo@huge-blue.ts.net", name: "")
        #expect(await runs.finished() == nil)
        let provider = AddMachineCardProvider(runs: runs)
        // A page script (no gesture) never opens a workspace on the machine.
        do {
            _ = try await provider.call(AddMachineCardProvider.openWorkspaceOp, params: .object([:]),
                                        context: PageCallContext(page: PageDescriptor.serverCards.id))
            Issue.record("openWorkspace ran without the person's click")
        } catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode) }
        #expect(host.opened.isEmpty)
        _ = try await provider.call(AddMachineCardProvider.openWorkspaceOp, params: .object([:]),
                                    context: PageCallContext(page: PageDescriptor.serverCards.id, userGesture: true, gestureEvent: 1))
        #expect(host.opened == ["ssh-leo@huge-blue.ts.net"])
    }

    @Test func theNameFieldNamesTheMachine() async {
        host.scripts = [[Self.report("lab", "huge-blue", ok: true, Self.okSteps)]]
        runs.begin()
        runs.add(destination: "huge-blue", name: "  lab ")
        _ = await runs.finished()
        #expect(host.commands == [.enroll(host: "huge-blue", name: "lab")])
        #expect(host.names == ["lab"], "the app connects it under the Name field's name")
        // Setup does the whole job: this Mac's agent profiles and the host's way back, no skips.
        #expect(HostCommand.enroll(host: "huge-blue", name: "lab").arguments
            == ["acp", "host", "enroll", "huge-blue", "--name", "lab", "--accept-new-host-key", "--harness", "local", "--reverse", "--json"])
    }

    @Test func aFailedStepFailsTheRunAndTryAgainRunsIt() async {
        let fail = Self.step("daemon", "fail", "daemon status timed out", fix: "Log in on the host once so launchd can start it.")
        host.scripts = [[Self.step("reach", "ok"), Self.step("install", "ok"), fail,
                         Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), Self.step("install", "ok"), fail])]]
        host.stops = [HostCLIStopFixture(message: "exit 1")]
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        #expect(await runs.finished() == "daemon: daemon status timed out")
        #expect(outcome == .failed)
        #expect(runs.run?.report?.ok == false)
        #expect(stops.isEmpty, "a report that came first is the answer, not the exit")
        #expect(host.connected.isEmpty, "a failed add does not connect")
        runs.copy("details")
        #expect(host.copied == ["details"])
        host.scripts = [[Self.report("hb", "hb", ok: true, Self.okSteps)]]
        runs.add(destination: "hb", name: "")
        _ = await runs.finished()
        #expect(host.commands.count == 2)
        #expect(outcome == .ready)
    }

    @Test func changeHostForgetsTheRunAndRunsNothing() async throws {
        let fail = Self.step("reach", "fail", "ssh: Could not resolve hostname huge-blu", fix: "Check the host name.")
        host.scripts = [[fail, Self.report("lab", "leo@huge-blu", ok: false, [fail])]]
        host.stops = [HostCLIStopFixture(message: "exit 1")]
        runs.begin(destination: "leo@huge-blu", name: "lab")
        let seq = runs.request.seq
        runs.add(destination: "leo@huge-blu", name: "lab")
        _ = await runs.finished()
        #expect(outcome == .failed)
        runs.cancel()
        #expect(runs.run == nil, "the card shows its fields again")
        #expect(runs.request.seq == seq && runs.request.destination == "leo@huge-blu", "the same open: the fields keep what was typed")
        #expect(host.commands.count == 1, "editing runs nothing")
        host.scripts = [[Self.report("lab", "leo@huge-blue", ok: true, Self.okSteps)]]
        runs.add(destination: "leo@huge-blue", name: "lab")
        _ = await runs.finished()
        #expect(host.commands == [.enroll(host: "leo@huge-blu", name: "lab"), .enroll(host: "leo@huge-blue", name: "lab")])
        #expect(outcome == .ready)
    }

    @Test func addAndFixAreOnlyForTheirOwnMode() async {
        host.scripts = [[Self.report("hb", "hb", ok: false, [Self.step("daemon", "fail", "down")])]]
        runs.beginCheck(host: "hb", machineID: "ssh-hb")
        _ = await runs.finished()
        runs.add(destination: "other", name: "")
        #expect(host.commands.count == 1, "Check Machine never enrolls")
        runs.begin()
        runs.fix()
        #expect(host.commands.count == 1, "Add Machine has no Fix")
    }

    @Test func aRunThatEndsWithoutAReportStopsWithWhy() async {
        host.scripts = [[Self.step("reach", "ok")]]
        host.stops = [HostCLIStopFixture(message: "error: unrecognized subcommand 'host'")]
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        #expect(await runs.finished() == "error: unrecognized subcommand 'host'")
        #expect(outcome == .failed && runs.run?.report == nil)
        #expect(stops == ["error: unrecognized subcommand 'host'"])
        // A run that ends cleanly without a report stops with no words (the card says "stopped").
        host.scripts = [[Self.step("reach", "ok")]]
        runs.add(destination: "hb", name: "")
        _ = await runs.finished()
        #expect(stops == [""])
    }

    @Test func aFailedInstallRunsTheAppsInstallThenEnrollAgain() async {
        let installFail = Self.step("install", "fail", "remote cmux-tui is missing", fix: "Install cmux-tui on the host.", reason: "not-this-program")
        host.scripts = [[Self.step("reach", "ok"), installFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), installFail])],
                        [Self.report("hb", "hb", ok: true, Self.okSteps)]]
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        _ = await runs.finished()
        #expect(host.installs == ["hb"])
        #expect(host.names == ["hb"], "the install connects it under the default name, the short host")
        #expect(host.commands.count == 2)
        #expect(runs.run?.machineID == "ssh-installed")
        #expect(host.connected.isEmpty, "the install connected it already")
        #expect(host.recorded.map(\.0) == ["ssh-installed"])
        #expect(runs.run?.events.contains(.install) == true && runs.run?.events.contains(.installEnd) == true)
        #expect(outcome == .ready)
    }

    @Test func aFailedAppInstallFailsTheInstallStep() async {
        let installFail = Self.step("install", "fail", "remote cmux-tui is missing", reason: "wrong-platform")
        host.scripts = [[Self.step("reach", "ok"), installFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), installFail])]]
        host.installAnswer = .failed("The download did not match its SHA-256 checksum.")
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        _ = await runs.finished()
        #expect(host.commands.count == 1)
        #expect(Array(runs.run?.events.suffix(3) ?? []) == [.install, .installEnd, .stop("The download did not match its SHA-256 checksum.")])
        #expect(outcome == .failed && runs.run?.report != nil)
    }

    @Test func anInstallFailureWithoutAnAppReasonIsShownNotInstalled() async {
        let probeFail = Self.step("install", "fail", "ssh: connection reset", fix: "Check again.")
        host.scripts = [[Self.step("reach", "ok"), probeFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), probeFail])]]
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        #expect(await runs.finished() == "install: ssh: connection reset")
        #expect(host.installs.isEmpty)
        #expect(host.commands.count == 1)
        #expect(HostLine.parse(Self.step("install", "fail", reason: "wrong-platform")) ==
            .step(HostStepResult(step: .install, state: .fail, reason: HostStepResult.wrongPlatform)))
    }

    @Test func finishedWaitsThroughAFixThatReplacesTheRun() async throws {
        // Check Machine's doctor is in flight and a caller (machine.doctor) waits on it.
        host.holdNextRun = true
        runs.beginCheck(host: "hb", machineID: "ssh-1")
        await Task.yield()
        let first = try #require(host.live)
        let waiter = Task { await runs.finished() }
        await Task.yield()
        // Fix replaces that run with another; the wait follows it instead of reporting the cancel.
        host.holdNextRun = true
        runs.fix()
        try await waitFor { host.commands.count == 2 }
        let second = try #require(host.live)
        first.finish()
        second.yield(Self.report("hb", "hb", ok: true, Self.okSteps))
        second.finish()
        #expect(await waiter.value == nil, "the tracked wait reports the fix's result, not the replaced run")
        #expect(host.commands.last == .doctor(host: "hb", fix: true))
    }

    @Test func anUnreachableHostDoesNotInstall() async {
        let reachFail = Self.step("reach", "fail", "ssh: connect to host hb port 22: Connection refused", fix: "Turn on Remote Login.")
        host.scripts = [[reachFail, Self.report("hb", "hb", ok: false, [reachFail, Self.step("install", "fail")])]]
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        #expect(await runs.finished() == "reach: ssh: connect to host hb port 22: Connection refused")
        #expect(host.installs.isEmpty)
    }

    @Test func linesReachTheCardAsTheyArrive() async throws {
        host.holdNextRun = true
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        await Task.yield()
        let live = try #require(host.live)
        live.yield(Self.step("reach", "ok", "ssh ok"))
        live.yield("connecting to hb…")
        try await waitFor { runs.run?.events.count == 2 }
        #expect(runs.run?.events.last == .line(Self.step("reach", "ok", "ssh ok")), "a log line is not relayed")
        #expect(outcome == .running)
        live.yield(Self.report("hb", "hb", ok: true, Self.okSteps))
        live.finish()
        _ = await runs.finished()
        #expect(outcome == .ready)
    }

    @Test func cancelStopsTheRun() async throws {
        host.holdNextRun = true
        runs.begin(destination: "hb")
        runs.add(destination: "hb", name: "")
        await Task.yield()
        #expect(outcome == .running)
        runs.cancel()
        #expect(runs.run == nil)
        #expect(host.recorded.isEmpty)
    }

    @Test func cancelAfterAnInstallReportDoesNotStartTheFallbackInstall() async throws {
        host.holdNextRun = true
        runs.begin(destination: "test-machine")
        runs.add(destination: "test-machine", name: "")
        try await waitFor { host.live != nil }
        let live = try #require(host.live)
        let installFail = Self.step("install", "fail", "use the app build", reason: "wrong-platform")
        live.yield(Self.report("test-machine", "test-machine", ok: false, [Self.step("reach", "ok"), installFail]))
        try await waitFor { runs.run?.events.count == 2 }
        #expect(outcome == .running, "the report arrived, but the stream has not ended")
        #expect(host.installs.isEmpty)

        let terminated = Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                host.termination = done
            }
        }
        try await waitFor { host.termination != nil }
        runs.cancel()
        live.finish()
        _ = await terminated.value

        #expect(host.installs.isEmpty, "a retained report must not start installation after Cancel")
        #expect(host.connected.isEmpty)
        #expect(host.recorded.isEmpty)
        #expect(runs.run == nil)
    }

    @Test func aDestinationFromOutsideOnlyFillsTheCard() async {
        runs.begin(destination: "hb", name: "lab")
        #expect(runs.run == nil, "the CLI or MCP never starts an enroll without a click")
        #expect(runs.request.destination == "hb" && runs.request.name == "lab")
        #expect(host.commands.isEmpty)
        // A second open while a run is in flight leaves the run and the open alone.
        let seq = runs.request.seq
        host.holdNextRun = true
        runs.add(destination: "hb", name: "lab")
        await Task.yield()
        runs.begin(destination: "other")
        #expect(outcome == .running)
        #expect(runs.request.seq == seq && runs.request.destination == "hb")
        #expect(host.commands.count == 1)
    }

    @Test func reopeningClearsTheLastRun() async {
        host.scripts = [[Self.report("hb", "hb", ok: true, Self.okSteps)]]
        runs.begin(destination: "hb")
        let seq = runs.request.seq
        runs.add(destination: "hb", name: "")
        _ = await runs.finished()
        runs.begin()
        #expect(runs.run == nil)
        #expect(runs.request.seq == seq + 1 && runs.request.destination == nil)
    }

    @Test func checkMachineRunsDoctorAndFixRunsItWithFix() async {
        let warn = Self.step("peer-back", "fail", "huge-blue cannot ssh back", fix: "Add this Mac's key on huge-blue.")
        host.scripts = [[Self.report("huge-blue", "huge-blue", ok: false, [Self.step("reach", "ok"), warn])],
                        [Self.report("huge-blue", "huge-blue", ok: true, Self.okSteps)]]
        runs.beginCheck(host: "leo@huge-blue", machineID: "ssh-abc")
        _ = await runs.finished()
        #expect(host.commands == [.doctor(host: "leo@huge-blue", fix: false)])
        #expect(runs.run?.name == "huge-blue")
        #expect(outcome == .failed)
        #expect(host.recorded.map(\.0) == ["ssh-abc"])
        runs.fix()
        _ = await runs.finished()
        #expect(host.commands.last == .doctor(host: "leo@huge-blue", fix: true))
        #expect(HostCommand.doctor(host: "hb", fix: true).arguments
            == ["acp", "host", "doctor", "hb", "--fix", "--harness", "local", "--reverse", "--json"])
        #expect(HostCommand.doctor(host: "hb", fix: false).arguments == ["acp", "host", "doctor", "hb", "--json"])
        #expect(outcome == .ready)
        #expect(host.recorded.count == 2)
        #expect(host.connected.isEmpty, "a check never connects")
    }

    // MARK: - Candidates

    @Test func candidatesComeFromTheCLIWithTheProbeFlag() async {
        let probed = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "100.64.0.2", os: "linux", online: true, alreadyPeer: false, sshOK: true)
        host.candidateAnswers = [[probed], nil]
        #expect(await runs.candidates(probe: false) == [probed])
        #expect(await runs.candidates(probe: true) == nil)
        #expect(host.probes == [false, true])
        #expect(probed.destination == "huge-blue.tail1.ts.net")
    }

    @Test func pickableFollowsOnlineInAppAndSSH() throws {
        let added = HostCandidate(name: "a", dnsName: "", ip: "", os: "", online: true, alreadyPeer: true, sshOK: true, inApp: true)
        let off = HostCandidate(name: "b", dnsName: "", ip: "", os: "", online: true, alreadyPeer: false, sshOK: false)
        let offline = HostCandidate(name: "c", dnsName: "", ip: "", os: "", online: false, alreadyPeer: false)
        let unprobed = HostCandidate(name: "d", dnsName: "", ip: "", os: "", online: true, alreadyPeer: false)
        #expect(!added.isPickable && !off.isPickable && !offline.isPickable && unprobed.isPickable)
        let wire = AddMachineCardProvider.candidate(off)
        #expect(wire["pickable"] == .bool(false) && wire["sshOK"] == .bool(false) && wire["destination"] == .string("b"))
    }

    /// Leo's ask-2971491c27: huge-blue, cmux16, air-blue and big-red were acpmux peers but not in the
    /// app, and the list greyed them out as Added. Added now means in the app; a peer the app lacks is
    /// an Agent peer and stays pickable, its port included.
    @Test func inAppPeerOnlyAndNewCandidatesPickApart() throws {
        let inApp = HostCandidate(name: "cmux16", dnsName: "cmux16.tail1.ts.net.", ip: "", os: "macOS", online: true, alreadyPeer: true,
                                  sshOK: true, peer: "cmux16", peerURL: "ssh://cmux16", inApp: true)
        let peerOnly = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "", os: "linux", online: true, alreadyPeer: true,
                                     sshOK: false, peer: "huge-blue", peerURL: "ssh://huge-blue:47822")
        let fresh = HostCandidate(name: "big-red", dnsName: "big-red.tail1.ts.net.", ip: "", os: "linux", online: true, alreadyPeer: false, sshOK: true)
        let offlinePeer = HostCandidate(name: "air-blue", dnsName: "", ip: "", os: "macOS", online: false, alreadyPeer: true, peer: "air-blue", peerURL: "ssh://air-blue")
        #expect(!inApp.isPickable)
        // The probe dialed port 22; the peer's own URL reaches it, so a failed probe does not grey it.
        #expect(peerOnly.isPickable)
        #expect(peerOnly.destination == "huge-blue", "the URL's port is the daemon's, not ssh's")
        #expect(peerOnly.peerDaemonPort == 47822)
        #expect(fresh.isPickable && fresh.destination == "big-red.tail1.ts.net")
        #expect(!offlinePeer.isPickable)
        #expect(HostCandidate(name: "w", dnsName: "w.ts.net", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ws://10.0.0.9:47811").destination == "w.ts.net")
        #expect(!HostCandidate(name: "w", dnsName: "w.ts.net", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ws://10.0.0.9:47811").isPickable)
        // A URL acpmux refuses (a path) is not a peer target: the row falls back to its own name.
        #expect(HostCandidate(name: "u", dnsName: "", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ssh://leo@u.ts.net/x").peerSSHTarget == nil)
    }

    @Test func addingAPickedPeerConnectsAndChecksWithoutEnrolling() async throws {
        host.scripts = [[Self.report("hb", "huge-blue", ok: true, Self.okSteps)]]
        runs.begin()
        // The card passes the picked peer's name; the field holds its ssh destination.
        runs.add(destination: "huge-blue", name: "", peer: "hb")
        #expect(runs.run?.destination == "huge-blue" && runs.run?.peer == "hb", "Try Again retries the peer")
        #expect(await runs.finished() == nil)
        // A picked peer gets the same setup an add does (approvals enrolled, profiles, peer-back),
        // not a check that leaves "run doctor --fix" warnings.
        #expect(host.commands == [.doctor(host: "hb", fix: true)], "no enroll for a peer")
        #expect(host.connected == ["huge-blue"], "ssh to the host; the daemon port stays acpmux's")
        #expect(host.names == ["hb"], "an empty Name field names it by its peer name")
        #expect(host.recorded.map(\.0) == ["ssh-huge-blue"])
        #expect(runs.run?.machineID == "ssh-huge-blue")
    }

    @Test func aPickedPeerThatCannotConnectFails() async throws {
        host.connectFails = true
        runs.begin()
        runs.add(destination: "cmux16", name: "", peer: "cmux16")
        #expect(await runs.finished() == "reach: \(AddMachineStrings.peerConnectFailed)")
        #expect(outcome == .failed)
        #expect(host.commands.isEmpty, "nothing runs when the connect failed")
        #expect(stops == [AddMachineStrings.peerConnectFailed])
    }

    /// The peer URL as acpmux reads it, then the app's real field parser (`SSHDestination`): the
    /// ssh destination never carries the daemon port, and it parses back to the same host.
    @Test func aPeerURLBecomesAnSSHDestinationThatParsesBackTheSame() throws {
        func target(_ url: String) -> HostCandidate {
            HostCandidate(name: "n", dnsName: "", ip: "", os: "", online: true, alreadyPeer: true, peer: "p", peerURL: url)
        }
        func connected(_ text: String) throws -> SSHDestination {
            let field = try #require(AddMachineServices.hostDestination(text), "\(text)")
            return try SSHDestination(parsing: field.host)
        }
        // A daemon port: ssh stays on its own port (22 or ~/.ssh/config), the port is carried apart.
        let hb = target("ssh://huge-blue:47822")
        #expect(hb.peerSSHDestination == "huge-blue" && hb.peerDaemonPort == 47822)
        let hbSSH = try connected(hb.destination)
        #expect(hbSSH.host == "huge-blue" && hbSSH.port == nil && hbSSH.user == nil)
        // No port: acpmux's default daemon port.
        #expect(target("ssh://cmux16").peerDaemonPort == HostCandidate.sshPeerDefaultDaemonPort)
        // user@.
        let user = target("ssh://leo@air-blue.tail1.ts.net")
        #expect(user.destination == "leo@air-blue.tail1.ts.net" && user.peerDaemonPort == 47811)
        let userSSH = try connected(user.destination)
        #expect(userSSH.user == "leo" && userSSH.host == "air-blue.tail1.ts.net" && userSSH.port == nil)
        #expect(AddMachineServices.hostDestination(user.destination)?.shortName == "air-blue")
        // Bracketed IPv6 without a port: the brackets stay, so no segment is read as a port.
        let v6 = target("ssh://leo@[fd7a:115c:a1e0::2]")
        #expect(v6.destination == "leo@[fd7a:115c:a1e0::2]" && v6.peerDaemonPort == 47811)
        #expect(AddMachineServices.hostDestination(v6.destination)?.host == "leo@[fd7a:115c:a1e0::2]")
        let v6SSH = try connected(v6.destination)
        #expect(v6SSH.user == "leo" && v6SSH.host == "fd7a:115c:a1e0::2" && v6SSH.port == nil)
        // Bracketed IPv6 with a daemon port.
        let v6Port = target("ssh://[fd7a:115c:a1e0::2]:47822")
        #expect(v6Port.destination == "[fd7a:115c:a1e0::2]" && v6Port.peerDaemonPort == 47822)
        let v6PortSSH = try connected(v6Port.destination)
        #expect(v6PortSSH.host == "fd7a:115c:a1e0::2" && v6PortSSH.port == nil)
        // A typed IPv6 host the field reads (bare v6 is ambiguous with a port, so brackets it is).
        #expect(AddMachineServices.hostDestination("leo@[fd7a::2]")?.host == "leo@[fd7a::2]")
        // A typed port is still refused: enroll takes none.
        #expect(AddMachineServices.hostDestination("huge-blue:2222") == nil)
        // URLs acpmux refuses are no target.
        #expect(target("ssh://huge-blue:0").peerSSHTarget == nil)
        #expect(target("ssh://huge-blue:x").peerSSHTarget == nil)
        #expect(target("ssh://@huge-blue").peerSSHTarget == nil)
        #expect(target("ws://10.0.0.9:47811").peerSSHTarget == nil)
    }

    @Test func theCandidatesObjectOfTheCLIParses() throws {
        let json = """
        {"tailnet":"Running","candidates":[{"name":"huge-blue","dns_name":"huge-blue.tail1.ts.net","ip":"100.64.0.2","os":"linux","online":true,"mine":true,"already_peer":false}]}
        """
        let list = try HostCandidate.parseList(Data(json.utf8))
        #expect(list.map(\.name) == ["huge-blue"])
        #expect(list[0].sshOK == nil)
        #expect(throws: (any Error).self) { try HostCandidate.parseList(Data("{}".utf8)) }
    }

    @Test func theCandidatesArrayParses() throws {
        let json = """
        [{"name":"huge-blue","dns_name":"huge-blue.tail1.ts.net.","ip":"100.64.0.2","os":"linux","online":true,"already_peer":false,"ssh_ok":true},
         {"name":"air","dns_name":"air.tail1.ts.net.","ip":"100.64.0.3","os":"macOS","online":false,"already_peer":true,"peer":"air","peer_url":"ssh://air:2222"}]
        """
        let list = try HostCandidate.parseList(Data(json.utf8))
        #expect(list.map(\.name) == ["huge-blue", "air"])
        #expect(list[0].sshOK == true && list[1].sshOK == nil)
        #expect(list[1].alreadyPeer && !list[1].online)
        #expect(list.allSatisfy { !$0.inApp }, "the app sets inApp, not the CLI")
        #expect(list[0].destination == "huge-blue.tail1.ts.net")
        #expect(list[1].peer == "air" && list[1].peerURL == "ssh://air:2222" && list[1].destination == "air" && list[1].peerDaemonPort == 2222)
    }

    // MARK: - Machines section

    @Test func theMachinesRowNamesTheStepTheLastCheckFlagged() {
        let store = MachineHealthStore()
        store.record("ssh-1", HostReport(name: "hb", host: "hb", ok: false, steps: [HostStepResult(step: .daemon, state: .fail)]))
        let report = store.reports["ssh-1"]
        let row = MachineSectionRow(id: "ssh-1", name: "hb", isConnected: true, isLocal: false, health: report?.health, healthStep: report?.worstStep?.step)
        #expect(row.health == .failing)
        #expect(row.healthStep == .daemon, "the page's status mark names the step the check flagged")
        #expect(MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true).health == nil)
    }

    // MARK: - The machine's name

    @Test func theNameFieldBecomesTheSidebarLabelAndSurvivesTheTransport() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@huge-blue.tail1.ts.net"))
        #expect(host.label == "huge-blue")
        let named = host.named(" lab \nsecond line")
        #expect(named.label == "lab")
        #expect(named.machineID == host.machineID, "a name never changes the route or the id")
        #expect(named.transportFields["name"] == "lab")
        #expect(SSHHost(transportFields: named.transportFields) == named)
        #expect(named.named("  ").label == "huge-blue")
        #expect(host.transportFields["name"] == nil)
    }

    /// Waits for main-actor state another task sets; no clock, a bounded number of yields.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}

/// A run that exits non-zero (the fixture's `HostCLIStop`, which lives in CmuxNextRemote).
struct HostCLIStopFixture: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
