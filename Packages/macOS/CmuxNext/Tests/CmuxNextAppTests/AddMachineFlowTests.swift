import AppKit
@testable import CmuxNextApp
import CmuxNextRemote
@testable import CmuxNextServer
import Foundation
import Testing

/// Add Machine (plans/cmux-next/add-machine-DESIGN.md): the CLI's JSON lines fill the checklist
/// live, an unknown future step shows by its raw name, the card walks pick, running, ready or
/// failed, a failed install step runs the app's own install and enroll again, Check Machine runs
/// doctor and Fix runs `--fix`, and the tailnet list loads, hides without Tailscale and greys out
/// what cannot be picked.
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
                        return AsyncThrowingStream { self.live = $0 }
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

    static let okSteps = ["reach", "install", "daemon", "harness", "peer", "peer-back", "identity"].map { step($0, "ok") }

    let host = FakeHost()
    let model: AddMachineModel

    init() {
        _ = NSApplication.shared
        model = AddMachineModel(services: host.services())
    }

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

    // MARK: - Checklist

    @Test func theChecklistFillsInLiveAndMarksTheNextStepRunning() {
        var list = HostChecklist()
        #expect(list.rows.map(\.step) == HostStep.known)
        #expect(list.rows.allSatisfy { $0.status == .pending })
        list.start()
        #expect(list.row(.reach)?.status == .running)
        list.apply(HostStepResult(step: .reach, state: .ok, detail: "ssh ok"))
        #expect(list.row(.reach)?.status == .done(.ok))
        #expect(list.row(.reach)?.detail == "ssh ok")
        #expect(list.row(.install)?.status == .running)
        #expect(list.row(.daemon)?.status == .pending)
        list.apply(HostStepResult(step: .install, state: .fixed))
        #expect(list.row(.daemon)?.status == .running)
    }

    @Test func anUnknownFutureStepShowsByItsRawNameAfterTheLastLine() {
        var list = HostChecklist()
        list.start()
        list.apply(HostStepResult(step: .reach, state: .ok))
        list.apply(HostStepResult(step: HostStep(rawValue: "firewall"), state: .warn, detail: "port 22 filtered"))
        #expect(list.rows.map(\.step.rawValue) == ["reach", "firewall", "install", "daemon", "harness", "peer", "peer-back", "identity"])
        #expect(list.row(HostStep(rawValue: "firewall"))?.status == .done(.warn))
        #expect(AddMachineStrings.step(HostStep(rawValue: "firewall")) == "firewall")
        #expect(list.row(.install)?.status == .running)
    }

    @Test func theReportSkipsWhatItDidNotRunAndAStopFailsTheRunningStep() {
        var list = HostChecklist()
        list.start()
        list.apply(HostStepResult(step: .reach, state: .fail, detail: "no route", fix: "Turn on Tailscale"))
        list.finish(HostReport(name: "hb", host: "hb", ok: false, steps: [HostStepResult(step: .reach, state: .fail, detail: "no route", fix: "Turn on Tailscale")]))
        #expect(list.failing?.step == .reach)
        #expect(list.failing?.fix == "Turn on Tailscale")
        #expect(list.rows.dropFirst().allSatisfy { $0.status == .done(.skip) })

        var stopped = HostChecklist()
        stopped.start()
        stopped.apply(HostStepResult(step: .reach, state: .ok))
        stopped.stop("cmux-tui: unknown subcommand host")
        #expect(stopped.failing?.step == .install)
        #expect(stopped.failing?.detail == "cmux-tui: unknown subcommand host")
        #expect(stopped.row(.daemon)?.status == .pending)
    }

    // MARK: - Flow

    @Test func addRunsEnrollAndEndsReady() async {
        host.scripts = [Self.okSteps + [Self.report("huge-blue", "leo@huge-blue.ts.net", ok: true, Self.okSteps)]]
        model.begin()
        #expect(model.phase == .pick)
        #expect(!model.canAdd)
        #expect(model.buttons.last == AddMachineButton(action: .add, key: .return, enabled: false))
        model.destination = "leo@huge-blue.ts.net"
        #expect(model.defaultName == "huge-blue")
        #expect(model.buttons.last?.enabled == true)
        model.perform(.add)
        #expect(model.phase == .running)
        #expect(model.buttons.map(\.enabled) == [true, false])
        #expect(await model.finished() == nil)
        #expect(host.commands == [.enroll(host: "leo@huge-blue.ts.net", name: "huge-blue")])
        guard case let .ready(report) = model.phase else { Issue.record("not ready: \(model.phase)"); return }
        #expect(report.ok)
        #expect(model.runName == "huge-blue")
        // Not connected by an install: the add connects it, records its health, and Open Workspace opens on it.
        #expect(host.connected == ["leo@huge-blue.ts.net"])
        #expect(host.recorded.map(\.0) == ["ssh-leo@huge-blue.ts.net"])
        #expect(model.buttons == [AddMachineButton(action: .done, key: .escape), AddMachineButton(action: .openWorkspace, key: .return)])
        #expect(model.perform(.openWorkspace))
        #expect(host.opened == ["ssh-leo@huge-blue.ts.net"])
    }

    @Test func theNameFieldNamesTheMachine() async {
        host.scripts = [[Self.report("lab", "huge-blue", ok: true, Self.okSteps)]]
        model.begin()
        model.destination = "huge-blue"
        model.name = "  lab "
        model.perform(.add)
        _ = await model.finished()
        #expect(host.commands == [.enroll(host: "huge-blue", name: "lab")])
        #expect(host.names == ["lab"], "the app connects it under the Name field's name")
        #expect(HostCommand.enroll(host: "huge-blue", name: "lab").arguments == ["acp", "host", "enroll", "huge-blue", "--name", "lab", "--json"])
    }

    @Test func aFailedStepStaysOpenWithTryAgainAndCopyDetails() async {
        let fail = Self.step("daemon", "fail", "daemon status timed out", fix: "Log in on the host once so launchd can start it.")
        host.scripts = [[Self.step("reach", "ok"), Self.step("install", "ok"), fail,
                         Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), Self.step("install", "ok"), fail])]]
        host.stops = [HostCLIStopFixture(message: "exit 1")]
        model.begin(destination: "hb")
        model.perform(.add)
        #expect(await model.finished() == "daemon: daemon status timed out")
        guard case .failed(let report?) = model.phase else { Issue.record("not failed: \(model.phase)"); return }
        #expect(!report.ok)
        #expect(model.checklist.failing?.step == .daemon)
        #expect(model.checklist.failing?.fix == "Log in on the host once so launchd can start it.")
        #expect(host.connected.isEmpty, "a failed add does not connect")
        #expect(model.buttons == [AddMachineButton(action: .copyDetails, key: nil), AddMachineButton(action: .tryAgain, key: .return)])
        #expect(!model.perform(.copyDetails))
        #expect(host.copied.first?.contains("daemon: fail - daemon status timed out (fix: Log in on the host once so launchd can start it.)") == true)
        host.scripts = [[Self.report("hb", "hb", ok: true, Self.okSteps)]]
        #expect(!model.perform(.tryAgain))
        _ = await model.finished()
        #expect(host.commands.count == 2)
        #expect(model.phase == .ready(HostReport(name: "hb", host: "hb", ok: true, steps: Self.okSteps.compactMap { line in
            if case let .step(step)? = HostLine.parse(line) { step } else { nil }
        })))
    }

    @Test func aRunThatEndsWithoutAReportFailsTheStepItStoppedOn() async {
        host.scripts = [[Self.step("reach", "ok")]]
        host.stops = [HostCLIStopFixture(message: "error: unrecognized subcommand 'host'")]
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(model.phase == .failed(nil))
        #expect(model.checklist.failing?.step == .install)
        #expect(model.checklist.failing?.detail == "error: unrecognized subcommand 'host'")
    }

    @Test func aFailedInstallRunsTheAppsInstallThenEnrollAgain() async {
        let installFail = Self.step("install", "fail", "remote cmux-tui is missing", fix: "Install cmux-tui on the host.", reason: "not-this-program")
        host.scripts = [[Self.step("reach", "ok"), installFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), installFail])],
                        [Self.report("hb", "hb", ok: true, Self.okSteps)]]
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(host.installs == ["hb"])
        #expect(host.names == ["hb"], "the install connects it under the default name, the short host")
        #expect(host.commands.count == 2)
        #expect(model.machineID == "ssh-installed")
        #expect(host.connected.isEmpty, "the install connected it already")
        #expect(host.recorded.map(\.0) == ["ssh-installed"])
        guard case .ready = model.phase else { Issue.record("not ready: \(model.phase)"); return }
    }

    @Test func aFailedAppInstallFailsTheInstallStep() async {
        let installFail = Self.step("install", "fail", "remote cmux-tui is missing", reason: "wrong-platform")
        host.scripts = [[Self.step("reach", "ok"), installFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), installFail])]]
        host.installAnswer = .failed("The download did not match its SHA-256 checksum.")
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(host.commands.count == 1)
        #expect(model.checklist.failing?.step == .install)
        #expect(model.checklist.failing?.detail == "The download did not match its SHA-256 checksum.")
        guard case .failed(_?) = model.phase else { Issue.record("not failed: \(model.phase)"); return }
    }

    @Test func anInstallFailureWithoutAnAppReasonIsShownNotInstalled() async {
        let probeFail = Self.step("install", "fail", "ssh: connection reset", fix: "Check again.")
        host.scripts = [[Self.step("reach", "ok"), probeFail, Self.report("hb", "hb", ok: false, [Self.step("reach", "ok"), probeFail])]]
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(host.installs.isEmpty)
        #expect(host.commands.count == 1)
        #expect(model.checklist.failing?.detail == "ssh: connection reset")
        #expect(HostLine.parse(Self.step("install", "fail", reason: "wrong-platform")) ==
            .step(HostStepResult(step: .install, state: .fail, reason: HostStepResult.wrongPlatform)))
    }

    @Test func finishedWaitsThroughAFixThatReplacesTheRun() async throws {
        // Check Machine's doctor is in flight and a caller (machine.doctor) waits on it.
        host.holdNextRun = true
        model.beginCheck(host: "hb", machineID: "ssh-1")
        await Task.yield()
        let first = try #require(host.live)
        let waiter = Task { await model.finished() }
        await Task.yield()
        // Fix replaces that run with another; the wait follows it instead of reporting the cancel.
        host.holdNextRun = true
        #expect(!model.perform(.fix))
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
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(host.installs.isEmpty)
        #expect(model.checklist.failing?.step == .reach)
    }

    @Test func linesFillTheChecklistAsTheyArrive() async throws {
        host.holdNextRun = true
        model.begin(destination: "hb")
        model.perform(.add)
        await Task.yield()
        let live = try #require(host.live)
        live.yield(Self.step("reach", "ok", "ssh ok"))
        try await waitFor { model.checklist.row(.reach)?.status == .done(.ok) }
        #expect(model.phase == .running)
        #expect(model.checklist.row(.install)?.status == .running)
        live.yield(Self.report("hb", "hb", ok: true, Self.okSteps))
        live.finish()
        _ = await model.finished()
        guard case .ready = model.phase else { Issue.record("not ready: \(model.phase)"); return }
    }

    @Test func cancelStopsTheRunAndCloses() async throws {
        host.holdNextRun = true
        model.begin(destination: "hb")
        model.perform(.add)
        await Task.yield()
        #expect(model.phase == .running)
        #expect(model.buttons.first == AddMachineButton(action: .cancel, key: .escape))
        #expect(model.perform(.cancel))
        #expect(model.phase == .pick)
        #expect(host.recorded.isEmpty)
    }

    @Test func aDestinationFromOutsideOnlyFillsTheCard() async {
        model.begin(destination: "hb", name: "lab")
        #expect(model.phase == .pick, "the CLI or MCP never starts an enroll without a click")
        #expect(model.destination == "hb" && model.name == "lab")
        #expect(host.commands.isEmpty)
        #expect(model.buttons.last == AddMachineButton(action: .add, key: .return, enabled: true))
        // A second open while a run is in flight leaves the run alone.
        host.holdNextRun = true
        model.perform(.add)
        await Task.yield()
        model.begin(destination: "other")
        #expect(model.phase == .running)
        #expect(model.destination == "hb")
        #expect(host.commands.count == 1)
    }

    @Test func reopeningClearsTheLastRun() async {
        host.scripts = [[Self.report("hb", "hb", ok: true, Self.okSteps)]]
        model.begin(destination: "hb")
        model.perform(.add)
        _ = await model.finished()
        #expect(model.perform(.done))
        model.begin()
        #expect(model.phase == .pick)
        #expect(model.destination.isEmpty)
        #expect(model.checklist == HostChecklist())
    }

    @Test func checkMachineRunsDoctorAndFixRunsItWithFix() async {
        let warn = Self.step("peer-back", "fail", "huge-blue cannot ssh back", fix: "Add this Mac's key on huge-blue.")
        host.scripts = [[Self.report("huge-blue", "huge-blue", ok: false, [Self.step("reach", "ok"), warn])],
                        [Self.report("huge-blue", "huge-blue", ok: true, Self.okSteps)]]
        model.beginCheck(host: "leo@huge-blue", machineID: "ssh-abc")
        _ = await model.finished()
        #expect(host.commands == [.doctor(host: "leo@huge-blue", fix: false)])
        #expect(model.runName == "huge-blue")
        #expect(model.buttons == [AddMachineButton(action: .copyDetails, key: nil), AddMachineButton(action: .fix, key: .return)])
        #expect(host.recorded.map(\.0) == ["ssh-abc"])
        #expect(!model.perform(.fix))
        _ = await model.finished()
        #expect(host.commands.last == .doctor(host: "leo@huge-blue", fix: true))
        #expect(HostCommand.doctor(host: "hb", fix: true).arguments == ["acp", "host", "doctor", "hb", "--fix", "--json"])
        #expect(model.buttons == [AddMachineButton(action: .done, key: .return)])
        #expect(host.recorded.count == 2)
        #expect(host.connected.isEmpty, "a check never connects")
    }

    // MARK: - Candidates

    @Test func candidatesLoadThenListAndPickFillsTheField() async throws {
        host.candidates = [HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "100.64.0.2", os: "linux", online: true, alreadyPeer: false, sshOK: true)]
        model.begin()
        #expect(model.candidates == .loading)
        try await waitFor { model.candidates != .loading }
        guard case let .loaded(list) = model.candidates, let first = list.first else { Issue.record("\(model.candidates)"); return }
        model.pick(first)
        #expect(model.destination == "huge-blue.tail1.ts.net")
        #expect(model.defaultName == "huge-blue")
    }

    @Test func theUnprobedListShowsFirstAndStaysWhenTheProbeFails() async throws {
        let unprobed = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "100.64.0.2", os: "linux", online: true, alreadyPeer: false)
        let probed = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "100.64.0.2", os: "linux", online: true, alreadyPeer: false, sshOK: true)
        host.candidateAnswers = [[unprobed], [probed]]
        model.begin()
        try await waitFor { model.candidates == .loaded([probed]) }
        #expect(host.probes == [false, true], "the plain list, then the probe")
        // A probe that fails or times out (nil) keeps the plain list showing.
        host.candidateAnswers = [[unprobed], nil]
        model.begin()
        try await waitFor { host.candidateAnswers.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.candidates == .loaded([unprobed]))
    }

    @Test func withoutTailscaleTheListIsUnavailableAndTheFieldStays() async throws {
        host.candidates = nil
        model.begin()
        try await waitFor { model.candidates != .loading }
        #expect(model.candidates == .unavailable)
        #expect(model.phase == .pick)
    }

    @Test func peersAndSSHOffAreGreyedWithWhy() throws {
        let added = HostCandidate(name: "a", dnsName: "", ip: "", os: "", online: true, alreadyPeer: true, sshOK: true, inApp: true)
        let off = HostCandidate(name: "b", dnsName: "", ip: "", os: "", online: true, alreadyPeer: false, sshOK: false)
        let offline = HostCandidate(name: "c", dnsName: "", ip: "", os: "", online: false, alreadyPeer: false)
        let unprobed = HostCandidate(name: "d", dnsName: "", ip: "", os: "", online: true, alreadyPeer: false)
        #expect(!added.isPickable && AddMachineCandidateList.badge(added) == AddMachineStrings.candidateAdded)
        #expect(!off.isPickable && AddMachineCandidateList.badge(off) == AddMachineStrings.candidateSSHOff)
        #expect(!offline.isPickable && AddMachineCandidateList.badge(offline) == AddMachineStrings.candidateOffline)
        #expect(unprobed.isPickable && AddMachineCandidateList.badge(unprobed) == nil)
        model.pick(added)
        #expect(model.destination.isEmpty)
    }

    /// Leo's ask-2971491c27: huge-blue, cmux16, air-blue and big-red were acpmux peers but not in the
    /// app, and the list greyed them out as Added. Added now means in the app; a peer the app lacks is
    /// an Agent peer and stays pickable, its port included.
    @Test func inAppPeerOnlyAndNewCandidatesPickAndBadgeApart() throws {
        let inApp = HostCandidate(name: "cmux16", dnsName: "cmux16.tail1.ts.net.", ip: "", os: "macOS", online: true, alreadyPeer: true,
                                  sshOK: true, peer: "cmux16", peerURL: "ssh://cmux16", inApp: true)
        let peerOnly = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "", os: "linux", online: true, alreadyPeer: true,
                                     sshOK: false, peer: "huge-blue", peerURL: "ssh://huge-blue:47822")
        let fresh = HostCandidate(name: "big-red", dnsName: "big-red.tail1.ts.net.", ip: "", os: "linux", online: true, alreadyPeer: false, sshOK: true)
        let offlinePeer = HostCandidate(name: "air-blue", dnsName: "", ip: "", os: "macOS", online: false, alreadyPeer: true, peer: "air-blue", peerURL: "ssh://air-blue")
        let inAppOnly = HostCandidate(name: "box", dnsName: "", ip: "", os: "", online: true, alreadyPeer: false, inApp: true)
        #expect(!inApp.isPickable && AddMachineCandidateList.badge(inApp) == AddMachineStrings.candidateAdded)
        #expect(!inAppOnly.isPickable && AddMachineCandidateList.badge(inAppOnly) == AddMachineStrings.candidateAdded)
        // The probe dialed port 22; the peer's own URL reaches it, so a failed probe does not grey it.
        #expect(peerOnly.isPickable && AddMachineCandidateList.badge(peerOnly) == AddMachineStrings.candidateAgentPeer)
        #expect(peerOnly.destination == "huge-blue", "the URL's port is the daemon's, not ssh's")
        #expect(peerOnly.peerDaemonPort == 47822)
        #expect(fresh.isPickable && AddMachineCandidateList.badge(fresh) == nil)
        #expect(fresh.destination == "big-red.tail1.ts.net")
        #expect(!offlinePeer.isPickable && AddMachineCandidateList.badge(offlinePeer) == AddMachineStrings.candidateOffline)
        #expect(HostCandidate(name: "w", dnsName: "w.ts.net", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ws://10.0.0.9:47811").destination == "w.ts.net")
        #expect(!HostCandidate(name: "w", dnsName: "w.ts.net", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ws://10.0.0.9:47811").isPickable)
        // A URL acpmux refuses (a path) is not a peer target: the row falls back to its own name.
        #expect(HostCandidate(name: "u", dnsName: "", ip: "", os: "", online: true, alreadyPeer: true, peerURL: "ssh://leo@u.ts.net/x").peerSSHTarget == nil)
    }

    @Test func addingAPickedPeerConnectsAndChecksWithoutEnrolling() async throws {
        let peer = HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "", os: "linux", online: true, alreadyPeer: true,
                                 peer: "hb", peerURL: "ssh://huge-blue:47822")
        host.candidates = [peer]
        host.scripts = [[Self.report("hb", "huge-blue", ok: true, Self.okSteps)]]
        model.begin()
        try await waitFor { model.candidates != .loading }
        model.pick(peer)
        #expect(model.destination == "huge-blue")
        #expect(model.canAdd)
        #expect(model.defaultName == "hb")
        #expect(host.commands.isEmpty, "a pick alone runs nothing")
        model.perform(.add)
        #expect(await model.finished() == nil)
        #expect(host.commands == [.doctor(host: "hb", fix: false)], "no enroll for a peer")
        #expect(host.connected == ["huge-blue"], "ssh to the host; the daemon port stays acpmux's")
        #expect(host.names == ["hb"])
        #expect(host.recorded.map(\.0) == ["ssh-huge-blue"])
        #expect(model.machineID == "ssh-huge-blue")
        #expect(model.buttons.last == AddMachineButton(action: .openWorkspace, key: .return))
    }

    @Test func aPickedPeerThatCannotConnectFailsAndAnEditedFieldEnrolls() async throws {
        let peer = HostCandidate(name: "cmux16", dnsName: "cmux16.tail1.ts.net.", ip: "", os: "macOS", online: true, alreadyPeer: true,
                                 peer: "cmux16", peerURL: "ssh://cmux16")
        host.connectFails = true
        model.begin()
        model.pick(peer)
        model.perform(.add)
        #expect(await model.finished() != nil)
        #expect(model.phase == .failed(nil))
        #expect(host.commands.isEmpty, "nothing runs when the connect failed")
        #expect(model.checklist.failing?.detail == AddMachineStrings.peerConnectFailed)
        // Typing over the field leaves the peer path: Add enrolls what was typed.
        host.connectFails = false
        model.begin()
        model.pick(peer)
        model.destination = "leo@cmux16"
        host.scripts = [[Self.report("cmux16", "leo@cmux16", ok: true, Self.okSteps)]]
        model.perform(.add)
        #expect(await model.finished() == nil)
        #expect(host.commands == [.enroll(host: "leo@cmux16", name: "cmux16")])
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
        #expect(row.healthHelp == AddMachineStrings.healthFailing(AddMachineStrings.step(.daemon)))
        #expect(MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true).healthHelp == nil)
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
