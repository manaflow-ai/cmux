import CmuxNextCompat
@testable import CmuxNextBrowser
@testable import CmuxNextWakeups
import Foundation
import Testing

/// Chromium's side of Energy Saver: the app's saver state reaches the fork's
/// `cmux_cef_set_energy_saver` once at the start and then once per edge, with cmux's own pages exempt; a
/// policy change that leaves the saver as it was makes no call, and a fork below the API gets none.
@MainActor
@Suite(.serialized) struct CEFEnergySaverTests {
    @Test func oneCallAtTheStartAndOnePerEdge() {
        let source = EnergyPolicySource()
        let recorder = Recorder()
        let saver = CEFEnergySaver { recorder.calls.append($0); return true }
        saver.follow(source, queue: MainWakeUpQueue(energy: source))
        #expect(recorder.calls == [false], "the start sends the state Chromium starts with")
        source.update(EnergyPolicy(saverReason: .setting))
        #expect(recorder.calls == [false, true])
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        source.update(EnergyPolicy(saverReason: .battery, suspended: true, onBattery: true))
        #expect(recorder.calls == [false, true], "the saver stayed on: a new reason, power source or sleep makes no call")
        source.update(EnergyPolicy(onBattery: true))
        #expect(recorder.calls == [false, true, false])
        source.update(.normal)
        #expect(recorder.calls == [false, true, false], "off again: no call")
        #expect(saver.isApplied)
    }

    @Test func aRefusedCallIsNotAppliedAndTheNextEdgeStillCalls() {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode))
        let recorder = Recorder()
        let saver = CEFEnergySaver { recorder.calls.append($0); return false }
        saver.follow(source, queue: MainWakeUpQueue(energy: source))
        #expect(recorder.calls == [true])
        #expect(!saver.isApplied)
        source.update(.normal)
        #expect(recorder.calls == [true, false])
    }

    /// A restarted Chromium (the host): an edge while no Chromium ran reached nobody, so
    /// the next ready sends the source's state again, edge or not, and ``CEFEnergySaver/isApplied`` is the
    /// new Chromium's answer.
    @Test func resyncSendsTheCurrentStateAfterAnEdgeNoChromiumTook() {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .battery, onBattery: true))
        let recorder = Recorder()
        let saver = CEFEnergySaver { recorder.calls.append($0); return recorder.answer }
        saver.follow(source, queue: MainWakeUpQueue(energy: source))
        #expect(recorder.calls == [true] && saver.isApplied)

        recorder.answer = false  // Chromium ended
        source.update(EnergyPolicy(onBattery: false))
        #expect(recorder.calls == [true, false])
        #expect(!saver.isApplied)

        recorder.answer = true  // the next Chromium is ready
        saver.resync()
        #expect(recorder.calls == [true, false, false], "the next Chromium did not get the state of the edge it missed")
        #expect(saver.isApplied, "applied stayed the answer of the Chromium that ended")
        source.update(.normal)
        #expect(recorder.calls.count == 3, "a repeated state after the resync made a call")
    }

    /// The source tells observers on its writer's thread. Changes told off the main thread reach Chromium
    /// only from the main wake queue's fire, and each queued hop reads the latest policy: three edges
    /// off main make one call, with the state the source ends in.
    @Test func changesOffTheMainThreadMakeOneCallWithTheLatestStateOnTheQueuesFire() async {
        let source = EnergyPolicySource()
        let uptime = Uptime()
        let queue = MainWakeUpQueue(energy: source, ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in ParkedWakeUpTimer() }
        let recorder = Recorder()
        let saver = CEFEnergySaver { recorder.calls.append($0); return true }
        saver.follow(source, queue: queue)

        await Task.detached {
            source.update(EnergyPolicy(saverReason: .setting))
            source.update(.normal)
            source.update(EnergyPolicy(saverReason: .lowPowerMode))
        }.value
        #expect(recorder.calls == [false], "a change off the main thread called Chromium before the queue's fire")
        #expect(queue.count == 3)

        uptime.now = 1_000_000_000
        queue.fire()
        #expect(recorder.calls == [false, true], "the hops sent an older state, or more than one call")
        #expect(queue.count == 0)
        #expect(saver.isApplied)
    }

    @Test func theForkAPIGuardsTheCall() {
        let below = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.energySaverForkAPI - 1, shimHasRendererPaths: true)
        let at = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.energySaverForkAPI, shimHasRendererPaths: false)
        #expect(!below.energySaver)
        #expect(at.energySaver)
    }

    @Test func belowTheForkAPITheRuntimeMakesNoCall() throws {
        SaverSpy.reset(forkAPI: CEFForkFeatures.energySaverForkAPI - 1)
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        let runtime = try Self.runtime(following: source)
        #expect(CEFEnergySaver.following(runtime) == nil)
        source.update(.normal)
        source.update(EnergyPolicy(saverReason: .setting))
        #expect(SaverSpy.calls.isEmpty)
    }

    @Test func theRuntimeSendsTheSchedulersPolicyWithCmuxPagesExempt() throws {
        SaverSpy.reset(forkAPI: CEFForkFeatures.energySaverForkAPI)
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        let runtime = try Self.runtime(following: source)
        let saver = try #require(CEFEnergySaver.following(runtime))
        #expect(SaverSpy.calls == [SaverSpy.Call(enabled: 1, scheme: "cmux-page")])
        #expect(saver.isApplied)
        source.update(EnergyPolicy(saverReason: .thermal, onBattery: true))
        #expect(SaverSpy.calls.count == 1, "a repeated state makes no call")
        source.update(.normal)
        #expect(SaverSpy.calls == [SaverSpy.Call(enabled: 1, scheme: "cmux-page"), SaverSpy.Call(enabled: 0, scheme: "cmux-page")])
        // Quit stopped Chromium: no call reaches the shim after.
        runtime.state = .shutDown
        source.update(EnergyPolicy(saverReason: .setting))
        #expect(SaverSpy.calls.count == 2)
        #expect(!saver.isApplied)
    }

    private static func runtime(following source: EnergyPolicySource) throws -> CEFRuntime {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-energy-saver-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try SaverSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), waitDeadlines: MainWakeUpQueue(energy: source))
        return runtime
    }
}

@MainActor
private final class Recorder {
    var calls: [Bool] = []
    /// What the apply answers: the fork took the call.
    var answer = true
}

/// The queue's uptime in ns: the queue reads it from any thread, the test's main actor moves it.
private nonisolated final class Uptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

/// A timer that never fires: the test fires the queue itself.
private nonisolated final class ParkedWakeUpTimer: MainWakeUpTimer {
    func arm(at _: UInt64, tolerance _: UInt64, now _: UInt64) {}
    func park() {}
}

/// A shim with a fork API number and a `cmux_shim_set_energy_saver` that records its calls (a C function
/// captures nothing).
private nonisolated enum SaverSpy {
    struct Call: Equatable {
        var enabled: Int32
        var scheme: String?
    }

    // crash-allow: the serialized suite's main-actor tests and the C stand-ins they call run on one thread
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    // crash-allow: the serialized suite's main-actor tests and the C stand-ins they call run on one thread
    nonisolated(unsafe) static var calls: [Call] = []

    static func reset(forkAPI: Int32) {
        self.forkAPI = forkAPI
        calls = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { SaverSpy.forkAPI }
        let setEnergySaver: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { enabled, scheme in
            SaverSpy.calls.append(Call(enabled: enabled, scheme: scheme.map { String(cString: $0) }))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_energy_saver": unsafeBitCast(setEnergySaver, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
