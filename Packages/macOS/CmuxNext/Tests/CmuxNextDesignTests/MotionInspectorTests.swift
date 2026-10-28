import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import QuartzCore
import Testing

/// The Motion Inspector (plans/cmux-next/motion-inspector.md): one time scale for every motion path, the
/// filter, frame steps and the live list. Host-free: an injected media clock, a fake-link scheduler and
/// layers in no window; the slow-motion timing on screen is MotionInspectorSlowMotionTests (GUI host).
@MainActor @Suite(.serialized) struct MotionInspectorTests {
    /// A media clock the test moves.
    final class MediaClock {
        var now: CFTimeInterval = 1000
    }

    /// An inspector on `clock` over the gates' settings (`DesignSettings.shared`: the gates report to the inspector
    /// registered there), with one fake-link scheduler for its frame count. Reduce Motion is pinned off until
    /// ``release(_:)``, so the gate's durations are the host's normal ones; the suite is serialized.
    static func inspector(_ clock: MediaClock, windows: [NSWindow] = [], clocks: [MotionClock] = []) -> MotionInspector {
        Motion.reduceMotionOverride = false
        let scheduler = FrameScheduler.testing(mediaTime: { clock.now }) { _ in MotionInspectorFakeLink() }
        return MotionInspector(now: { clock.now }, windows: { windows }, design: .shared, scheduler: { scheduler },
                               clocks: { clocks })
    }

    /// Stops `inspector` and gives Reduce Motion back to the system.
    static func release(_ inspector: MotionInspector) {
        inspector.stop()
        Motion.reduceMotionOverride = nil
    }

    // MARK: Time scale values

    @Test func theTimeScaleHasFiveStepsAndPauseHasRateZero() {
        #expect(MotionTimeScale.allCases.map(\.value) == [1, 2, 5, 10, 0])
        #expect(MotionTimeScale.x5.rate == 0.2)
        #expect(MotionTimeScale.paused.rate == 0)
        #expect(MotionTimeScale(value: 10) == .x10)
        #expect(MotionTimeScale(value: 3) == nil)
        // A path that cannot pause plays at the slowest step while paused, so it can still be watched.
        #expect(MotionTimeScale.paused.startScale == 10)
        #expect(MotionTimeScale.x1.startScale == 1)
    }

    // MARK: Layer time base

    @Test func aRetimeKeepsTheLocalTimeAndAStepMovesIt() {
        let base = MotionTimebase.identity
        let slowed = base.retimed(rate: 0.1, atParent: 50)
        #expect(slowed.localTime(atParent: 50) == 50, "no jump at the retime")
        #expect(abs(slowed.localTime(atParent: 60) - 51) < 1e-9, "10 s of wall time is 1 s of animation at 10x")
        let paused = slowed.retimed(rate: 0, atParent: 60)
        #expect(abs(paused.localTime(atParent: 90) - 51) < 1e-9, "paused: the time stands still")
        let stepped = paused.stepped(by: 1.0 / 120)
        #expect(abs(stepped.localTime(atParent: 90) - (51 + 1.0 / 120)) < 1e-9)
        let back = stepped.stepped(by: -2.0 / 120)
        #expect(abs(back.localTime(atParent: 90) - (51 - 1.0 / 120)) < 1e-9, "a step back moves the time back")
    }

    // MARK: Zero cost when off

    @Test func offEveryHookIsInertAndTheStaticsAreRealTime() {
        #expect(!MotionInspector.isActive)
        #expect(DesignSettings.shared.activeMotionInspector == nil)
        #expect(MotionInspector.startScale == 1)
        #expect(MotionInspector.clockRate == 1)
        let animation = CABasicAnimation(keyPath: "opacity")
        MotionInspector.noteAnimation(animation)
        #expect(animation.value(forKey: MotionInspector.tagKey) == nil, "nothing tags an animation while nobody inspects")
        #expect(MotionInspector.noteClockRun(NSObject(), trace: "x") == nil)
        var built = false
        _ = MotionInspector.noteAppKit({ built = true; return "kind" }(), view: nil, curve: .stepped, completion: nil)
        #expect(!built, "a hook's arguments are not even built while nobody inspects")
    }

    // MARK: Lifecycle, filter and policy

    @Test func startSlowsTheStaticsAndStopRestoresEverything() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.setTimeScale(.x5)
        #expect(MotionInspector.isActive && inspector.isInspecting)
        #expect(MotionInspector.startScale == 5 && MotionInspector.clockRate == 0.2)
        #expect(inspector.design.motionInspection.timeScale == .x5)
        inspector.setFilter(kind: .sidebarRows)
        #expect(inspector.design.motionInspection.excludedCategories == Set(MotionCategory.allCases).subtracting([.sidebar]))
        let policy = Motion.basePolicy(of: inspector.design).for(.tabs)
        #expect(!policy.categoryAnimates, "a category the filter leaves out applies in one frame")
        #expect(Motion.basePolicy(of: inspector.design).for(.sidebar).categoryAnimates)
        inspector.stop()
        #expect(!MotionInspector.isActive && !inspector.isInspecting)
        #expect(MotionInspector.startScale == 1 && MotionInspector.clockRate == 1)
        #expect(inspector.design.motionInspection == .off)
        #expect(Motion.basePolicy(of: inspector.design).for(.tabs).categoryAnimates)
    }

    @Test func motionTimeRunsAtTheRateAndStandsStillWhilePaused() {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.setTimeScale(.x10)
        clock.now += 1
        #expect(abs(inspector.motionNow - 0.1) < 1e-9)
        inspector.setTimeScale(.paused)
        clock.now += 5
        #expect(abs(inspector.motionNow - 0.1) < 1e-9)
        inspector.step(frames: 2)
        #expect(abs(inspector.motionNow - (0.1 + 2 * inspector.frameInterval)) < 1e-9)
    }

    // MARK: Records

    @Test func aGateFadeIsRecordedWithItsOwnerCurveAndEnd() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.start()
        let layer = CALayer()
        layer.opacity = 0
        let animation = Motion.feedback.set(layer, "opacity", to: Float(1), fade: .fadeIn)
        let record = try #require(inspector.records.last)
        #expect(record.category == .feedback)
        #expect(record.site?.hasPrefix("CmuxNextDesignTests/MotionInspectorTests.swift:") == true, "owner: \(record.owner)")
        #expect(record.property == "opacity")
        #expect(record.from == "0" && record.to == "1")
        #expect(record.runs == .renderServer)
        let seconds = Motion.feedback.duration(.fadeIn)
        #expect(record.curve == .timed(seconds: seconds, name: "easeOut"))
        #expect(record.expectedEnd.map { abs($0 - seconds) < 1e-9 } == true)
        #expect((animation?.value(forKey: MotionInspector.tagKey) as? NSNumber)?.uint64Value == record.id, "tagged for the scan")
    }

    @Test func aSpringRecordsResponseDampingAndPerceivedDuration() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.start()
        _ = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: .zero), to: NSValue(point: CGPoint(x: 0, y: 40)))
        let record = try #require(inspector.records.last)
        let spring = Motion.sidebar.spring(.move)
        guard case .spring(let response, let damping, let perceived) = record.curve else {
            Issue.record("not a spring: \(record.curve)")
            return
        }
        #expect(abs(response - spring.response) < 1e-6)
        #expect(abs(damping - spring.dampingFraction) < 1e-6)
        #expect(abs(perceived - spring.perceivedDuration) < 0.01)
        #expect(record.category == .sidebar)
    }

    @Test func oneTurnsStartsFromOneSiteAreOneRecordOfSeveralLayers() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.start()
        // A sidebar insert moves every row below it: one call site, one turn, many layers.
        for _ in 0..<12 { _ = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: .zero), to: NSValue(point: .zero)) }
        #expect(inspector.records.count == 1)
        #expect(inspector.records.first?.layers == 12)
        clock.now += 0.03
        _ = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: .zero), to: NSValue(point: .zero))
        #expect(inspector.records.count == 2, "the next turn's insert is its own record")
    }

    @Test func theSidebarRowsKindListsOnlySidebarRowSites() {
        let row = MotionInspectorRecord(id: 1, site: "CmuxNextSidebar/SidebarDragSpring.swift:112", ownerType: nil, category: .sidebar,
                                        kind: "spring.position", property: "position", from: nil, to: nil, curve: .stepped,
                                        runs: .renderServer, gated: true, start: 0, expectedEnd: nil)
        var hover = row
        hover.site = "CmuxNextSidebar/SidebarResizeHandle.swift:134"
        var tab = row
        tab.site = "CmuxNextTabs/TabMotion.swift:116"
        tab.category = .tabs
        #expect(MotionInspector.FilterKind.sidebarRows.matches(row))
        #expect(!MotionInspector.FilterKind.sidebarRows.matches(hover))
        #expect(MotionInspector.FilterKind.tabStrip.matches(tab))
        #expect(!MotionInspector.FilterKind.tabStrip.matches(row))
    }

    @Test func aTabStripTweenIsRecordedWithItsValuesAndCategory() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.start()
        let move = try #require(MotionMove.tween(.tabMove, in: Motion.tabs))
        _ = move.additive("position.x", from: NSNumber(value: -40.0), to: NSNumber(value: 0.0))
        let record = try #require(inspector.records.last)
        #expect(record.category == .tabs)
        #expect(record.property == "position.x")
        #expect(record.from == "-40" && record.to == "0")
        #expect(record.site?.hasPrefix("CmuxNextDesignTests/MotionInspectorTests.swift:") == true)
    }

    @Test func aRecordEndsWhenItsCurveRunsOutAndCountsDroppedFrames() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        inspector.start()
        let id = inspector.add(kind: "test", property: "opacity", from: nil, to: nil, curve: .timed(seconds: 0.1, name: "easeOut"),
                               runs: .renderServer, ownerType: nil, start: 0, end: 0.1)
        inspector.frameForTesting(rawElapsed: 1.0 / 60, interval: 1.0 / 60)
        // A frame that came three refreshes after the previous one: two refreshes had no main-thread frame.
        clock.now += 0.05
        inspector.frameForTesting(rawElapsed: 3.0 / 60, interval: 1.0 / 60)
        var record = try #require(inspector.records.first { $0.id == id })
        #expect(record.frames == 2 && record.droppedFrames == 2 && record.isRunning)
        clock.now += 0.06
        inspector.frameForTesting(rawElapsed: 1.0 / 60, interval: 1.0 / 60)
        record = try #require(inspector.records.first { $0.id == id })
        #expect(!record.isRunning && record.ended == 0.1)
    }

    @Test func endedRecordsArePrunedRunningOnesKept() {
        var records: [MotionInspectorRecord] = []
        for index in 0..<(MotionInspector.endedKept + 30) {
            var record = MotionInspectorRecord(id: UInt64(index), site: nil, ownerType: nil, category: nil, kind: "k", property: "p",
                                               from: nil, to: nil, curve: .stepped, runs: .main, gated: true, start: Double(index),
                                               expectedEnd: nil)
            if index >= 10 { record.ended = Double(index) }
            records.append(record)
        }
        let pruned = MotionInspector.pruned(records)
        #expect(pruned.filter(\.isRunning).count == 10)
        #expect(pruned.filter { !$0.isRunning }.count == MotionInspector.endedKept)
        #expect(pruned.last?.id == UInt64(MotionInspector.endedKept + 29), "the newest ended ones stay")
    }

    // MARK: CPU springs

    @MainActor final class Stepper: MotionAnimating {
        var steps: [Double] = []
        let restAfter: Int
        init(restAfter: Int) { self.restAfter = restAfter }
        func motionStep(_ tick: FrameTick) -> Bool {
            steps.append(tick.elapsed)
            return steps.count < restAfter
        }
    }

    @Test func aClockStepsAtTheRateParksWhilePausedAndStepsOneFrame() throws {
        let clock = MediaClock()
        let scheduler = FrameScheduler.testing(mediaTime: { clock.now }) { _ in MotionInspectorFakeLink() }
        let motion = MotionClock(scheduler: { scheduler })
        let inspector = Self.inspector(clock, clocks: [motion])
        defer { Self.release(inspector) }
        inspector.setTimeScale(.x10)
        let stepper = Stepper(restAfter: 100)
        motion.run(stepper, trace: "test.stepper")
        let record = try #require(inspector.records.last)
        #expect(record.runs == .main && record.kind == "clock.test.stepper")
        scheduler.frameDidFire(timestamp: 1.0, refreshInterval: 1.0 / 60)
        scheduler.frameDidFire(timestamp: 1.0 + 1.0 / 60, refreshInterval: 1.0 / 60)
        try #require(stepper.steps.count == 2)
        #expect(abs(stepper.steps[1] - 1.0 / 600) < 1e-9, "a 10x clock steps a tenth of the frame")
        #expect(inspector.records.last?.mainFrames == 2, "each step's main-thread time is recorded")

        inspector.setTimeScale(.paused)
        scheduler.frameDidFire(timestamp: 1.0 + 2.0 / 60, refreshInterval: 1.0 / 60)
        #expect(stepper.steps.count == 2, "paused: the clock steps nothing")
        #expect(motion.isParkedByInspector && !motion.isIdle && !scheduler.hasLink, "parked: no display link, animators kept")
        let step = inspector.step(frames: 1)
        #expect(step.clockFrames == 1 && stepper.steps.count == 3)
        #expect(abs(stepper.steps[2] - inspector.frameInterval) < 1e-9, "a step is one display frame of animation")

        inspector.setTimeScale(.x1)
        #expect(!motion.isParkedByInspector && scheduler.hasLink, "leaving pause runs the clock again")
        scheduler.frameDidFire(timestamp: 2.0, refreshInterval: 1.0 / 60)
        #expect(stepper.steps.count == 4)
    }

    @Test func stoppingWhilePausedResumesParkedClocks() {
        let clock = MediaClock()
        let scheduler = FrameScheduler.testing(mediaTime: { clock.now }) { _ in MotionInspectorFakeLink() }
        let motion = MotionClock(scheduler: { scheduler })
        let inspector = Self.inspector(clock, clocks: [motion])
        defer { Self.release(inspector) }
        inspector.setTimeScale(.paused)
        let stepper = Stepper(restAfter: 3)
        motion.run(stepper, trace: "test.paused")
        scheduler.frameDidFire(timestamp: 1.0, refreshInterval: 1.0 / 60)
        #expect(motion.isParkedByInspector)
        inspector.stop()
        #expect(!motion.isParkedByInspector && scheduler.hasLink)
        scheduler.frameDidFire(timestamp: 1.1, refreshInterval: 1.0 / 60)
        #expect(stepper.steps.count == 1)
    }

    // MARK: Root layers

    @Test func theTimeScaleRetimesEachWindowsRootAndStopRestoresIt() throws {
        let clock = MediaClock()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        content.wantsLayer = true
        window.contentView = content
        let root = try #require(MotionInspector.rootLayer(of: window))
        let inspector = Self.inspector(clock, windows: [window])
        defer { Self.release(inspector) }
        inspector.setTimeScale(.x10)
        #expect(abs(root.speed - 0.1) < 1e-6)
        clock.now += 2
        let parent = { root.superlayer?.convertTime(clock.now, from: nil) ?? clock.now }
        let shown = MotionTimebase(of: root).localTime(atParent: parent())
        inspector.setTimeScale(.x1)
        #expect(root.speed == 1, "back at 1x the root runs at real speed")
        #expect(abs(MotionTimebase(of: root).localTime(atParent: parent()) - shown) < 1e-6,
                "from the time it showed: no running animation jumps to its end")
        inspector.setTimeScale(.paused)
        #expect(root.speed == 0)
        let before = root.timeOffset
        let step = inspector.step(frames: -1)
        #expect(step.layers == 1)
        #expect(abs(root.timeOffset - (before - inspector.frameInterval)) < 1e-9, "a step back moves the window's time back one frame")
        inspector.stop()
        #expect(root.speed == 1 && root.timeOffset == 0 && root.beginTime == 0, "stop gives the root its own time base back")
    }

    // MARK: Socket

    @Test func theSocketActionsDriveTheModel() throws {
        let clock = MediaClock()
        let inspector = Self.inspector(clock)
        defer { Self.release(inspector) }
        let scaled = try #require(inspector.handle("time_scale", ["value": 5]))
        #expect(scaled["time_scale"] as? Double == 5 && inspector.timeScale == .x5)
        #expect(inspector.handle("time_scale", ["value": 3])?["error"] != nil)
        _ = inspector.handle("filter", ["kind": "tabStrip"])
        #expect(inspector.filterKind == .tabStrip && inspector.keptCategories == [.tabs])
        #expect(inspector.handle("filter", ["kind": "nope"])?["error"] != nil)
        _ = inspector.handle("filter", ["categories": ["sidebar", "panes"]])
        #expect(inspector.keptCategories == [.sidebar, .panes] && inspector.filterKind == nil)
        let stepped = try #require(inspector.handle("step", ["frames": 1]))
        #expect(inspector.timeScale == .paused && stepped["step"] != nil)
        let far = try #require(inspector.handle("step", ["frames": 100_000])?["step"] as? [String: Any])
        let seconds = try #require(far["seconds"] as? Double)
        #expect(seconds <= Double(MotionInspector.maximumStep) * inspector.frameInterval + 0.01, "a step is clamped: \(seconds) s")
        #expect(inspector.handle("read", [:]) == nil, "the older debug.motion actions pass through")
        let stopped = try #require(inspector.handle("inspect_stop", [:]))
        #expect(stopped["records"] != nil && !inspector.isInspecting)
        #expect(stopped["inspecting"] as? Bool == false)
    }

    // MARK: Web pages

    @Test func aWebThemeCarriesTheRateOnlyWhileSlowed() {
        let design = DesignSettings.shared
        let saved = design.motionInspection
        defer { design.motionInspection = saved }
        design.motionInspection = .off
        #expect(WebTheme.motionRate(of: design) == nil)
        design.motionInspection.timeScale = .x5
        #expect(WebTheme.motionRate(of: design) == 0.2)
        #expect(WebTheme.bootstrapScript.contains("playbackRate"))
    }
}

extension MotionInspector {
    /// One inspector frame of `rawElapsed` seconds on a display of `interval` (tests).
    func frameForTesting(rawElapsed: Double, interval: Double) {
        _ = tickForTesting(FrameTick(timestamp: now(), elapsed: min(rawElapsed, 1.0 / 30), rawElapsed: rawElapsed, refreshInterval: interval))
    }
}

/// A display link that never fires: the test fires the scheduler's frames itself.
@MainActor
private final class MotionInspectorFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
