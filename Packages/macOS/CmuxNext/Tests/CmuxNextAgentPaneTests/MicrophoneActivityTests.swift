import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextDictation

/// The composer's outside-dictation mark (design/composer-dictation.md): the host watches the
/// microphone only while a composer has the keyboard, tells the page when another app takes or
/// releases it, and never opens it.
@MainActor struct MicrophoneActivityTests {
    private final class Owner {}

    /// A source that answers each read at once, on the main actor.
    @MainActor private final class FakeSource: MicrophoneActivitySource {
        var next = MicrophoneActivity.State.idle
        var namesProcesses = true
        var reads = 0
        private var deliver: (@MainActor (MicrophoneActivity.SourceEvent) -> Void)?
        var isListening: Bool { deliver != nil }

        func start(_ deliver: @escaping @MainActor (MicrophoneActivity.SourceEvent) -> Void) {
            self.deliver = deliver
            requestRead()
        }

        func stop() { deliver = nil }

        func requestRead() {
            guard let deliver else { return }
            reads += 1
            deliver(.read(next, namesProcesses: namesProcesses))
        }

        func send(_ event: MicrophoneActivity.SourceEvent) { deliver?(event) }
    }

    @Test func listenersRunOnlyWhileSomeoneWatches() {
        let activity = MicrophoneActivity(claims: DictationMicrophoneClaims(), source: FakeSource())
        #expect(!activity.isListening)
        let first = Owner(), second = Owner()
        activity.watch(first) { _ in }
        activity.watch(second) { _ in }
        activity.unwatch(first)
        activity.unwatch(second)
        // The last watcher out removes every listener and forgets the state.
        #expect(!activity.isListening)
        #expect(activity.state == .idle)
    }

    @Test func watchersHearEachChangeOnce() {
        let source = FakeSource()
        let activity = MicrophoneActivity(claims: DictationMicrophoneClaims(), source: source)
        var heard: [MicrophoneActivity.State] = []
        let owner = Owner()
        activity.watch(owner) { heard.append($0) }
        source.next = MicrophoneActivity.State(active: true, bundleId: "com.openai.codex", name: "ChatGPT")
        activity.refresh()
        activity.refresh()
        source.next = .idle
        activity.refresh()
        #expect(heard.map(\.active) == [false, true, false])
        #expect(heard[1].name == "ChatGPT")
        activity.unwatch(owner)
    }

    @Test func nothingIsReadWithNoWatcher() {
        let source = FakeSource()
        let activity = MicrophoneActivity(claims: DictationMicrophoneClaims(), source: source)
        activity.refresh()
        #expect(source.reads == 0)
    }

    /// Before 14.2 a running device names no process: while cmux's own dictation holds the
    /// microphone, no outside mark shows.
    @Test func aDeviceReadingIsHiddenWhileOwnDictationHoldsTheMicrophone() {
        let source = FakeSource(), claims = DictationMicrophoneClaims(), owner = Owner(), dictation = Owner()
        source.next = MicrophoneActivity.State(active: true, bundleId: nil, name: nil)
        source.namesProcesses = false
        let activity = MicrophoneActivity(claims: claims, source: source)
        activity.tellsProcessesApart = false
        activity.watch(owner) { _ in }
        #expect(activity.state.active)
        claims.claim(dictation) {}
        #expect(activity.state == .idle)
        // The release re-reads: cmux's own input stopped, so the device no longer runs.
        source.next = .idle
        let reads = source.reads
        claims.release(dictation)
        #expect(source.reads == reads + 1)
        #expect(activity.state == .idle)
        activity.unwatch(owner)
    }

    /// Reads that run on CoreAudio's queue, and how many ran on the main thread.
    /// Not main-actor isolated like the suite: CoreAudio's queue calls `record()`.
    nonisolated private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0, onMain = 0
        func record() {
            lock.withLock {
                reads += 1
                if Thread.isMainThread { onMain += 1 }
            }
        }
        var counts: (reads: Int, onMain: Int) { lock.withLock { (reads, onMain) } }
    }

    /// The NIGHTLY 85b0999 hang (2026-11-10): a CoreAudio read that took 30 s ran on the main
    /// thread. Here the read blocks until the test lets it go, and the main actor runs on: watching
    /// returns at once, the watcher hears the read when it ends, and the refreshes asked for while
    /// it blocked made one more read, not one each.
    /// If the read ran on the main actor, `watch` would wait on the gate forever: the time limit
    /// turns that into a failure.
    @Test(.timeLimit(.minutes(1))) func aSlowCoreAudioReadNeverHoldsTheMainActor() async {
        let gate = DispatchSemaphore(value: 0), log = ReadLog()
        let outside = MicrophoneActivity.State(active: true, bundleId: "com.electron.wispr-flow", name: "Wispr Flow")
        let source = CoreAudioMicrophoneSource(read: {
            log.record()
            gate.wait()
            return (outside, namesProcesses: true)
        }, listens: false)
        let activity = MicrophoneActivity(claims: DictationMicrophoneClaims(), source: source)
        activity.isAuthorized = { false }
        let (changes, heard) = AsyncStream.makeStream(of: MicrophoneActivity.State.self)
        let owner = Owner()
        activity.watch(owner) { heard.yield($0) }
        // The first read is blocked on the source's queue; the main actor still answers.
        #expect(activity.state == .idle)
        activity.refresh()
        activity.refresh()
        activity.refresh()
        for _ in 0..<4 { gate.signal() }
        for await state in changes where state.active { break }
        #expect(activity.state.name == "Wispr Flow")
        activity.unwatch(owner)
        heard.finish()
        let counts = log.counts
        #expect(counts.onMain == 0)
        #expect(counts.reads <= 2)
    }

    @Test func thePageEventCarriesTheApp() {
        let event = AgentPageEvent.micActivity(.init(active: true, bundleId: "com.electron.wispr-flow", name: "Wispr Flow"))
        #expect(event.kind == "micActivity")
        #expect(event.value.value(at: ["active"])?.boolValue == true)
        #expect(event.value.value(at: ["name"])?.stringValue == "Wispr Flow")
        #expect(AgentPageEvent.micActivity(.idle).value.value(at: ["bundleId"]) == nil)
    }

    /// A watcher whose meter seam counts opens and closes, with an outside app holding the input.
    @MainActor private final class Rig {
        let activity: MicrophoneActivity
        let claims = DictationMicrophoneClaims()
        let source: FakeSource
        var next: MicrophoneActivity.State {
            get { source.next }
            set { source.next = newValue }
        }
        var authorized = true
        var opened: [DictationAudioLevelMeter] = []
        var closes = 0
        var asked = 0

        init() {
            let source = FakeSource()
            source.next = MicrophoneActivity.State(active: true, bundleId: "com.electron.wispr-flow", name: "Wispr Flow")
            self.source = source
            activity = MicrophoneActivity(claims: claims, source: source)
            activity.tellsProcessesApart = true
            activity.isAuthorized = { [unowned self] in
                self.asked += 1
                return self.authorized
            }
            activity.openMeter = { [unowned self] in self.opened.append($0) }
            activity.closeMeter = { [unowned self] in self.closes += 1 }
        }
    }

    @Test func theMeterRunsForAnOutsideAppWithPermission() {
        let rig = Rig(), owner = Owner()
        var heard: [MicrophoneActivity.State] = []
        rig.activity.watch(owner) { heard.append($0) }
        #expect(rig.opened.count == 1)
        #expect(rig.activity.state.metered)
        #expect(heard.last?.metered == true)
        // The other app releases the input: the meter closes and the page hears it.
        rig.next = .idle
        rig.activity.refresh()
        #expect(rig.closes == 1)
        #expect(heard.last == .idle)
        rig.activity.unwatch(owner)
    }

    @Test func noPermissionKeepsTheDrawnPulse() {
        let rig = Rig(), owner = Owner()
        rig.authorized = false
        rig.activity.watch(owner) { _ in }
        #expect(rig.opened.isEmpty)
        #expect(rig.activity.state.active)
        #expect(!rig.activity.state.metered)
        rig.activity.unwatch(owner)
    }

    @Test func beforeMacOS14_2NothingIsMetered() {
        let rig = Rig(), owner = Owner()
        rig.activity.tellsProcessesApart = false
        rig.activity.watch(owner) { _ in }
        #expect(rig.opened.isEmpty)
        // The permission is not even read.
        #expect(rig.asked == 0)
        rig.activity.unwatch(owner)
    }

    @Test func theLastUnwatchClosesTheMeter() {
        let rig = Rig(), first = Owner(), second = Owner()
        rig.activity.watch(first) { _ in }
        rig.activity.watch(second) { _ in }
        rig.activity.unwatch(first)
        #expect(rig.closes == 0)
        rig.activity.unwatch(second)
        #expect(rig.closes == 1)
        #expect(!rig.activity.state.metered)
    }

    @Test func ownDictationClosesTheMeterBeforeItListens() {
        let rig = Rig(), owner = Owner(), dictation = Owner()
        rig.activity.watch(owner) { _ in }
        rig.claims.claim(dictation) {}
        #expect(rig.closes == 1)
        #expect(!rig.activity.state.metered)
        // Its session ends while the other app still dictates: the meter opens again.
        rig.claims.release(dictation)
        #expect(rig.opened.count == 2)
        #expect(rig.activity.state.metered)
        rig.activity.unwatch(owner)
        // Nobody watches: a claim opens or closes nothing.
        rig.claims.claim(dictation) {}
        rig.claims.release(dictation)
        #expect(rig.opened.count == 2)
    }

    @Test func levelsReachWatchersAndATapThatEndsStaysClosed() async {
        let rig = Rig(), owner = Owner()
        var levels: [Float] = []
        rig.activity.watch(owner, onLevel: { levels.append($0) }, onChange: { _ in })
        let meter = rig.opened.first
        meter?.update(rms: 1)
        // The tap closes on its own (a device change): the stream ends.
        meter?.finish()
        await rig.activity.levelForwarding?.value
        #expect(levels == [1])
        #expect(!rig.activity.state.metered)
        rig.activity.refresh()
        #expect(rig.opened.count == 1)
        // The next outside session meters again.
        let held = rig.next
        rig.next = .idle
        rig.activity.refresh()
        rig.next = held
        rig.activity.refresh()
        #expect(rig.opened.count == 2)
        rig.activity.unwatch(owner)
    }

    @Test func aClosedMetersQueuedLevelNeverReachesTheNextMeter() async {
        let rig = Rig(), owner = Owner()
        var levels: [Float] = []
        rig.activity.watch(owner, onLevel: { levels.append($0) }, onChange: { _ in })
        let first = rig.opened.first, firstForwarding = rig.activity.levelForwarding
        // A level sits in the first meter's stream when the default input changes: that meter
        // closes and a second one opens before the stream is read.
        first?.update(rms: 1)
        rig.activity.defaultInputChanged()
        await firstForwarding?.value
        #expect(levels.isEmpty)
        // The second meter's levels still arrive.
        let second = rig.opened.last
        second?.update(rms: 0.5)
        second?.finish()
        await rig.activity.levelForwarding?.value
        #expect(levels.count == 1)
        rig.activity.unwatch(owner)
    }

    @Test func aNewDefaultInputMovesTheMeter() {
        let rig = Rig(), owner = Owner()
        rig.activity.watch(owner) { _ in }
        rig.activity.defaultInputChanged()
        #expect(rig.closes == 1)
        #expect(rig.opened.count == 2)
        #expect(rig.activity.state.metered)
        rig.activity.unwatch(owner)
    }

    @Test func theLevelEventRoundsToThreeDecimals() {
        let event = AgentPageEvent.micLevel(0.123_56)
        #expect(event.kind == "micLevel")
        #expect(event.value.value(at: ["level"])?.doubleValue == 0.124)
        #expect(AgentPageEvent.micLevel(1.7).value.value(at: ["level"])?.doubleValue == 1)
        var metered = MicrophoneActivity.State(active: true, bundleId: nil, name: nil)
        #expect(AgentPageEvent.micActivity(metered).value.value(at: ["metered"]) == nil)
        metered.metered = true
        #expect(AgentPageEvent.micActivity(metered).value.value(at: ["metered"])?.boolValue == true)
    }

    @Test func thePageAsksToWatchWithABool() {
        #expect(AgentPaneRequest(body: ["method": "dictation.watchMicrophone", "params": ["on": true]]) == .watchMicrophone(true))
        #expect(AgentPaneRequest(body: ["method": "dictation.watchMicrophone", "params": ["on": "yes"]]) == .unsupported("dictation.watchMicrophone"))
        #expect(AgentPageOps.methods["dictation.watchMicrophone"] == "dictation.watchMicrophone")
    }
}
