import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// The settings broadcasts (`Motion.reduceMotionDidChange`, `Motion.speedDidChange`,
/// `DesignSettings.hoverCardsDidChange`, `WindowMaterialView.inactiveDimDidChange`) are one injected
/// ``AppearanceSignals``. The system's display options are observed once for the app, readers on
/// hidden nodes do no work until they show, and Observation readers re-read Reduce Motion only
/// while visible.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppearanceSignalsTests {
    /// The system's display options a test sets, and the center their notice is posted on.
    @MainActor final class System {
        var options = AppearanceSignals.DisplayOptions()
        let center = NotificationCenter()
        private(set) lazy var events = AppEvents(center: center)

        /// Changes the options and posts the notice, as the system does.
        func set(_ change: (inout AppearanceSignals.DisplayOptions) -> Void) {
            change(&options)
            center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
    }

    /// Settings whose signals read `system`'s options and observe its notice. The caller keeps the
    /// settings alive while it uses their signals (the signals hold them weakly).
    private static func design(_ system: System) -> DesignSettings {
        let design = DesignSettings(display: { system.options })
        design.signals.observeDisplayOptions(through: system.events)
        return design
    }

    @Test func manyReadersShareTheAppsOneDisplayOptionsObserver() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        var calls = 0
        let readers = (0..<50).map { index in
            signals.subscribe([.displayOptions], owner: "reader.\(index)") { calls += 1 }
        }
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        #expect(system.events.subscriberCount(name) == 1, "each reader observed the notice itself")
        #expect(system.events.isObserving(name))
        system.set { $0.increaseContrast = true }
        #expect(system.events.deliveries(name) == 1)
        #expect(calls == 50, "each reader is called once per change")
        #expect(signals.display.increaseContrast)
        // A notice with nothing changed (an option no reader follows) calls nobody.
        system.set { _ in }
        #expect(calls == 50)
        withExtendedLifetime(readers) {}
    }

    @Test func aSystemReduceMotionFlipRaisesReduceMotionAndMotion() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        var heard: [AppearanceSignals.Signal] = []
        let watches = [AppearanceSignals.Signal.reduceMotion, .motion, .hoverCards, .inactiveDim].map { signal in
            signals.subscribe([signal], owner: "\(signal)") { heard.append(signal) }
        }
        #expect(!signals.reduceMotion)
        system.set { $0.reduceMotion = true }
        #expect(signals.reduceMotion)
        #expect(heard == [.reduceMotion, .motion])
        withExtendedLifetime(watches) {}
    }

    @Test func thePinRaisesReduceMotionEvenWhenTheValueStays() {
        let system = System()
        system.options.reduceMotion = true
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        var calls = 0
        let watch = signals.subscribe([.reduceMotion], owner: "mirror") { calls += 1 }
        signals.reduceMotionOverride = true
        #expect(calls == 1, "a host that mirrors the pin missed it")
        signals.reduceMotionOverride = true
        #expect(calls == 1, "setting the same pin again is no change")
        signals.reduceMotionOverride = false
        #expect(calls == 2)
        #expect(!signals.reduceMotion)
        withExtendedLifetime(watch) {}
    }

    @Test func designSettingsRaiseTheirSignals() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        var heard: [AppearanceSignals.Signal: Int] = [:]
        let watches = AppearanceSignals.Signal.allCases.map { signal in
            signals.subscribe([signal], owner: "\(signal)") { heard[signal, default: 0] += 1 }
        }
        design.hoverCardsEnabled = false
        #expect(heard == [.hoverCards: 1])
        design.inactiveWindowDim = 0.2
        #expect(heard == [.hoverCards: 1, .inactiveDim: 1])
        design.animationSpeed = design.animationSpeed == .fast ? .normal : .fast
        design.animationsEnabled.toggle()
        design.disabledAnimationCategories = [.tabs]
        #expect(heard[.motion] == 3)
        #expect(heard[.reduceMotion] == nil, "a speed or switch change is no Reduce Motion change")
        heard = [:]
        design.calmMode = .calm
        #expect(heard[.motion] == 1)
        #expect(heard[.hoverCards] == 1)
        #expect(heard[.reduceMotion] == 1, "calm mode turns Reduce Motion on")
        #expect(heard[.displayOptions] == nil)
        withExtendedLifetime(watches) {}
    }

    @Test func aHiddenSubscriberGetsOneMissedCallOnShow() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls: [EventCall] = []
        let watch = signals.subscribe([.reduceMotion], node: node, delivery: .whenVisible, owner: "hidden") { calls.append($0) }
        for _ in 0..<10 {
            system.set { $0.reduceMotion.toggle() }
        }
        #expect(calls.isEmpty, "a hidden subscriber did view work")
        #expect(node.deferredCount == 1)
        node.set(.visible)
        #expect(calls == [.missed])
        system.set { $0.reduceMotion.toggle() }
        #expect(calls == [.missed, .posted])
        watch.cancel()
        system.set { $0.reduceMotion.toggle() }
        #expect(calls == [.missed, .posted], "a cancelled subscription was called")
    }

    /// A capture vote makes a hidden node render (an agent's screenshot of a hidden
    /// workspace draws its views), so a subscriber that missed a signal hears it in the vote's turn and
    /// hears each later one while the vote holds; page visibility stays hidden.
    @Test func aCapturedHiddenSubscriberIsCurrentForTheCapture() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        let node = VisibilityNode(root: "workspace", own: .hidden)
        var calls: [EventCall] = []
        let watch = signals.subscribe([.reduceMotion], node: node, delivery: .whenVisible, owner: "captured") { calls.append($0) }
        system.set { $0.reduceMotion.toggle() }
        #expect(calls.isEmpty)
        let vote = node.captureVote(reason: "agent.screenshot", stayHidden: true)
        #expect(node.effective == .hidden && node.wantsFrames)
        #expect(calls == [.missed], "the capture drew a view that missed a signal")
        system.set { $0.reduceMotion.toggle() }
        #expect(calls == [.missed, .posted], "a signal to a captured view waited for a show")
        vote.release()
        system.set { $0.reduceMotion.toggle() }
        #expect(calls == [.missed, .posted], "a released node did view work")
        withExtendedLifetime(watch) {}
    }

    @Test func aReleasedSubscriptionIsNotCalled() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        var calls = 0
        var watch: AppearanceSignals.Subscription? = signals.subscribe([.displayOptions], owner: "gone") { calls += 1 }
        #expect(signals.subscriberCount(.displayOptions) == 1)
        watch = nil
        system.set { $0.reduceTransparency = true }
        #expect(calls == 0)
        #expect(signals.subscriberCount(.displayOptions) == 0)
        _ = watch
    }

    /// The test phase's scenario: a Reduce Motion toggle with 60 workspaces open re-reads only the
    /// visible workspace's view.
    @Test func aReduceMotionToggleAtSixtyWorkspacesEvaluatesOnlyTheVisibleOne() {
        let system = System()
        let design = Self.design(system)
        defer { withExtendedLifetime(design) {} }
        let signals = design.signals
        let frames = Frames()
        let window = VisibilityNode(root: "window", own: .visible)
        let workspaces = (0..<60).map { VisibilityNode("workspace.\($0)", own: $0 == 0 ? .visible : .hidden, parent: window) }
        var reads = Array(repeating: 0, count: 60)
        var applied = Array(repeating: [Bool](), count: 60)
        let watches = workspaces.enumerated().map { index, node in
            VisibleObservation(node, owner: "workspace.motion", on: frames.work) {
                reads[index] += 1
                return signals.reduceMotion
            } apply: { value in
                applied[index].append(value)
            }
        }
        #expect(reads.allSatisfy { $0 == 1 }, "each view reads its first value once")
        system.set { $0.reduceMotion = true }
        frames.frame()
        #expect(applied[0] == [false, true], "the visible view did not follow Reduce Motion")
        #expect(reads[1...].allSatisfy { $0 == 1 }, "a hidden workspace's view re-read Reduce Motion")
        #expect(applied[1...].allSatisfy { $0 == [false] })
        workspaces[7].set(.visible)
        #expect(reads[7] == 2, "a workspace that shows reads once")
        #expect(applied[7] == [false, true])
        for watch in watches { watch.cancel() }
        frames.stop()
    }
}

/// A main-thread scheduler whose frames the test fires.
@MainActor
private final class Frames {
    let work: MainWorkScheduler
    private let clock = UptimeBox()
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let clock = self.clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now })) { _ in FakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, 17 ms after the last one.
    func frame() {
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

@MainActor
private final class UptimeBox {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private final class FakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
