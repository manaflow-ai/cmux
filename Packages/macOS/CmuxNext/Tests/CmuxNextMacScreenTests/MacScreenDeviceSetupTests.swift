import CmuxNextDaemon
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// Set Up cmux and Start cmux on Screen Sharing read the daemon's `device-setup` step events and reply the way
/// it means them, and show their buttons only where they can work: a Mac, a daemon that knows the
/// command, Start only while the Mac is offline.
@MainActor @Suite struct MacScreenDeviceSetupTests {
    // MARK: Lines

    @Test func readsEachStepState() throws {
        for (word, state) in [("ok", MacScreenDeviceStep.State.ok), ("changed", .changed), ("warn", .warn), ("fail", .fail), ("skip", .skip)] {
            let line = #"{"device":"studio-mac","step":"launch","state":"\#(word)","detail":"opened cmux NIGHTLY","fix":""}"#
            #expect(MacScreenDeviceLine.parse(line) == .step(MacScreenDeviceStep(device: "studio-mac", step: "launch", state: state,
                                                                                 detail: "opened cmux NIGHTLY", fix: nil)))
        }
    }

    @Test func anUnknownStateReadsAsAWarningNeverAPass() {
        let line = #"{"device":"m","step":"app","state":"exploded","detail":"d"}"#
        guard case let .step(step)? = MacScreenDeviceLine.parse(line) else { Issue.record("not a step"); return }
        #expect(step.state == .warn)
        #expect(step.fix == nil)
    }

    @Test func readsTheFixOfAFailedStep() {
        let line = #"{"device":"m","step":"reach","state":"fail","detail":"ssh refused","fix":"Turn on Remote Login on m."}"#
        guard case let .step(step)? = MacScreenDeviceLine.parse(line) else { Issue.record("not a step"); return }
        #expect(step.fix == "Turn on Remote Login on m.")
    }

    @Test func readsTheSummaryLine() {
        let line = #"{"device":"studio-mac","summary":"started","changed":["launch"]}"#
        #expect(MacScreenDeviceLine.parse(line) == .summary(MacScreenDeviceSummary(device: "studio-mac", summary: "started", changed: ["launch"])))
    }

    @Test func skipsWhatIsNotALine() {
        for text in ["", "   ", "starting…", "{not json", #"{"other":"shape"}"#, "[1,2]"] {
            #expect(MacScreenDeviceLine.parse(text) == nil, "\(text)")
        }
    }

    // MARK: The daemon's words

    @Test func readsAStepEventAndTheReplyFromTheDaemon() {
        // A step event's line carries the event name too; the reply is the summary.
        let event: CmuxNextDaemon.JSONValue = .object(["event": .string("device-setup-step"), "device": .string("studio-mac"),
                                                       "step": .string("launch"), "state": .string("changed"), "detail": .string("opened")])
        #expect(MacScreenDeviceSetup.line(event) == .step(MacScreenDeviceStep(device: "studio-mac", step: "launch", state: .changed, detail: "opened")))
        let reply: CmuxNextDaemon.JSONValue = .object(["device": .string("studio-mac"), "summary": .string("started"),
                                                       "changed": .array([.string("launch")])])
        #expect(MacScreenDeviceSetup.line(reply) == .summary(MacScreenDeviceSummary(device: "studio-mac", summary: "started", changed: ["launch"])))
        #expect(MacScreenDeviceSetup.line(.object(["ok": .bool(true)])) == nil)
    }

    @Test func anUnknownCommandIsAnOlderDaemon() {
        for message in ["unknown variant `device-setup`, expected one of …", "unknown command: device-setup", "Unknown cmd device-setup"] {
            #expect(DeviceSetupRequest.isUnknownCommand(DaemonError.command(cmd: "device-setup", message: message, code: nil)),
                    "\(message)")
        }
        #expect(!DeviceSetupRequest.isUnknownCommand(DaemonError.command(cmd: "device-setup", message: "no route to studio-mac", code: nil)))
        #expect(!DeviceSetupRequest.isUnknownCommand(CancellationError()))
    }

    // MARK: Buttons

    static let both = MacScreenDeviceVerbs([.setup, .start])

    @Test func anOfflineMacShowsStart() {
        let row = MacScreenDeviceSetupRow.make(isMac: true, online: false, verbs: Self.both, run: nil)
        #expect(row.showsStart)
        #expect(row.showsSetup)
        #expect(row.canRun(.start))
    }

    @Test func anOnlineMacShowsSetUpButNotStart() {
        let row = MacScreenDeviceSetupRow.make(isMac: true, online: true, verbs: Self.both, run: nil)
        #expect(!row.showsStart)
        #expect(row.showsSetup)
    }

    @Test func anUnknownVerbHidesItsButton() {
        let old = MacScreenDeviceSetupRow.make(isMac: true, online: false, verbs: MacScreenDeviceVerbs([]), run: nil)
        #expect(old == .none)
        let onlySetup = MacScreenDeviceSetupRow.make(isMac: true, online: false, verbs: MacScreenDeviceVerbs([.setup]), run: nil)
        #expect(!onlySetup.showsStart)
        #expect(onlySetup.showsSetup)
        // Before the verbs are read, nothing shows.
        #expect(MacScreenDeviceSetupRow.make(isMac: true, online: false, verbs: nil, run: nil) == .none)
    }

    @Test func aPhoneShowsNoButton() {
        #expect(MacScreenDeviceSetupRow.make(isMac: false, online: false, verbs: Self.both, run: nil) == .none)
    }

    @Test func aRunningStartKeepsItsButtonDisabledWhileTheMacComesOnline() {
        let row = MacScreenDeviceSetupRow.make(isMac: true, online: true, verbs: Self.both, run: MacScreenDeviceRun(verb: .start))
        #expect(row.showsStart)
        #expect(!row.canRun(.start))
        #expect(!row.canRun(.setup))
    }

    // MARK: Runs

    @Test func aRunEndsByItsExitAndSteps() {
        var run = MacScreenDeviceRun(verb: .start)
        run.take(.step(MacScreenDeviceStep(device: "m", step: "reach", state: .ok)))
        run.take(.step(MacScreenDeviceStep(device: "m", step: "launch", state: .changed)))
        run.end(nil)
        #expect(run.phase == .succeeded)

        var failed = MacScreenDeviceRun(verb: .setup)
        failed.take(.step(MacScreenDeviceStep(device: "m", step: "reach", state: .fail, detail: "refused")))
        failed.end(MacScreenDeviceRunStop(message: "device-setup: reach failed"))
        // The step says why: the CLI's last line is not repeated.
        #expect(failed.phase == .failed(""))

        var stopped = MacScreenDeviceRun(verb: .start)
        stopped.end(MacScreenDeviceRunStop(message: "no route to m"))
        #expect(stopped.phase == .failed("no route to m"))

        var tooOld = MacScreenDeviceRun(verb: .start)
        tooOld.end(MacScreenDeviceRunStop(unknownCommand: true, message: "unknown variant"))
        #expect(tooOld.phase == .needsNewerCmux)
    }

    @Test func aStepThatReportsAgainReplacesItsLine() {
        var run = MacScreenDeviceRun(verb: .setup)
        run.take(.step(MacScreenDeviceStep(device: "m", step: "app", state: .warn)))
        run.take(.step(MacScreenDeviceStep(device: "m", step: "app", state: .changed)))
        #expect(run.steps.map(\.state) == [.changed])
    }

    /// A fake daemon: each run yields `lines` and ends with `stop`, recording the verb and name.
    static func runner(lines: [MacScreenDeviceLine], stop: MacScreenDeviceRunStop? = nil,
                       seen: @escaping ([String]) -> Void = { _ in }) -> MacScreenDeviceSetup.Runner {
        { verb, name in
            seen([verb.rawValue, name])
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish(throwing: stop)
            }
        }
    }

    static func settle(_ until: @MainActor () -> Bool) async {
        for _ in 0..<200 where !until() { await Task.yield() }
    }

    @Test func startRunsTheDaemonsVerbAndRefreshesOnSuccess() async {
        var seen: [[String]] = []
        let setup = MacScreenDeviceSetup(runner: Self.runner(lines: [
            .step(MacScreenDeviceStep(device: "studio-mac", step: "reach", state: .ok, detail: "ssh")),
            .step(MacScreenDeviceStep(device: "studio-mac", step: "launch", state: .changed, detail: "opened cmux NIGHTLY")),
            .summary(MacScreenDeviceSummary(device: "studio-mac", summary: "started", changed: ["launch"])),
        ], seen: { seen.append($0) }))
        var succeeded: [String] = []
        setup.succeeded = { id, _ in succeeded.append(id) }
        #expect(setup.row(id: "d1", isMac: true, online: false).showsStart)
        setup.run(.start, id: "d1", name: "studio-mac")
        await Self.settle { setup.runs["d1"]?.isRunning == false }
        #expect(setup.runs["d1"]?.phase == .succeeded)
        #expect(setup.runs["d1"]?.steps.map(\.step) == ["reach", "launch"])
        #expect(setup.runs["d1"]?.summary?.changed == ["launch"])
        #expect(succeeded == ["d1"])
        #expect(seen == [["start", "studio-mac"]])
        setup.dismiss(id: "d1")
        #expect(setup.runs["d1"] == nil)
    }

    @Test func aDaemonThatRefusesTheCommandHidesTheButtons() async {
        let setup = MacScreenDeviceSetup(runner: Self.runner(lines: [], stop: MacScreenDeviceRunStop(unknownCommand: true, message: "unknown variant")))
        setup.run(.start, id: "d1", name: "studio-mac")
        await Self.settle { setup.runs["d1"]?.isRunning == false }
        #expect(setup.runs["d1"]?.phase == .needsNewerCmux)
        #expect(!setup.row(id: "d1", isMac: true, online: false).showsStart)
        #expect(!setup.row(id: "d1", isMac: true, online: false).showsSetup)
        #expect(!setup.row(id: "d2", isMac: true, online: true).showsSetup)
    }

    @Test func aHostThatBlocksThisMacOffersNoSetUp() {
        let row = MacScreenDeviceSetupRow.make(isMac: true, online: false, verbs: .all, run: nil)
        let blocked = row.blocking(allowsRequests: false)
        #expect(!blocked.showsSetup)
        #expect(blocked.showsStart)
        #expect(row.blocking(allowsRequests: true) == row)
    }

    @Test func noDaemonShowsNoButton() {
        let setup = MacScreenDeviceSetup()
        #expect(setup.row(id: "d1", isMac: true, online: false) == .none)
        setup.runner = Self.runner(lines: [])
        #expect(setup.row(id: "d1", isMac: true, online: false).showsStart)
    }
}
