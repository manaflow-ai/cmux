#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextInput
import ObjectiveC
import QuartzCore
import Testing

/// The input-turn dirty-view recorder (p04-input-093): its hooks go in on install and come out on
/// remove, a dirty call in an input turn is recorded with its placement against the target, calls
/// outside a turn, clearing sets and off-main calls pass through, and sites and turns stay bounded.
/// Serialized: the hooks replace process-wide IMPs.
@MainActor
@Suite(.serialized)
struct InputDirtyRecorderTests {
    private final class TargetView: NSView {}
    private final class InsideView: NSView {}
    private final class OutsideView: NSView {}
    private nonisolated final class OffMainLayer: CALayer {}

    /// A clock that moves 1 ms per read.
    private final class Ticks {
        var nanos: UInt64 = 0
        func read() -> UInt64 {
            nanos += 1_000_000
            return nanos
        }
    }

    private static let dirtySelectors: [(AnyClass, Selector)] = [
        (NSView.self, #selector(setter: NSView.needsDisplay)),
        (NSView.self, #selector(NSView.setNeedsDisplay(_:))),
        (NSView.self, #selector(setter: NSView.needsLayout)),
        (NSView.self, #selector(setter: NSView.needsUpdateConstraints)),
        (CALayer.self, #selector(CALayer.setNeedsDisplay as (CALayer) -> () -> Void)),
        (CALayer.self, #selector(CALayer.setNeedsDisplay(_:))),
        (CALayer.self, #selector(CALayer.setNeedsLayout)),
    ]

    private func implementations() -> [IMP?] {
        Self.dirtySelectors.map { root, selector in class_getInstanceMethod(root, selector).map(method_getImplementation) }
    }

    /// A content view holding the target (with a child) and a sibling outside it.
    private func tree() -> (root: NSView, target: TargetView, inside: InsideView, outside: OutsideView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let target = TargetView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let inside = InsideView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        let outside = OutsideView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        target.addSubview(inside)
        root.addSubview(target)
        root.addSubview(outside)
        return (root, target, inside, outside)
    }

    @Test func installReplacesEveryDirtyMethodAndRemovePutsTheOriginalsBack() async {
        let before = implementations()
        #expect(before.allSatisfy { $0 != nil })
        let recorder = InputDirtyRecorder()
        recorder.install()
        #expect(recorder.isInstalled)
        let installed = implementations()
        for (index, imp) in installed.enumerated() {
            #expect(imp != before[index], "\(Self.dirtySelectors[index].1) is not hooked")
        }
        recorder.install()
        #expect(implementations() == installed, "a second install must not hook twice")
        recorder.remove()
        #expect(!recorder.isInstalled)
        #expect(implementations() == before, "remove must put every original IMP back")
        let report = await recorder.report()
        #expect(!report.installed)
        #expect(report.sites.isEmpty)
    }

    @Test func aDirtyCallInAnInputTurnIsRecordedWithItsPlacement() async throws {
        let ticks = Ticks()
        let recorder = InputDirtyRecorder(now: { ticks.read() })
        recorder.install()
        defer { recorder.remove() }
        let views = tree()
        views.outside.needsDisplay = true // outside a turn: not recorded
        recorder.beginDispatch(.key, target: views.target)
        views.inside.needsLayout = true
        views.outside.needsDisplay = true
        views.outside.needsDisplay = false // a clearing set dirties nothing
        recorder.endDispatch()
        views.outside.needsUpdateConstraints = true // after the dispatch, before the commit
        recorder.commitWillRun()
        recorder.commitDidRun()
        views.outside.needsLayout = true // the turn closed: not recorded

        let report = await recorder.report()
        #expect(report.installed)
        #expect(report.dirtyCalls == 3)
        #expect(report.offTargetCalls == 2)
        #expect(report.droppedCalls == 0)
        let first = try #require(report.sites.first)
        #expect(first.offTarget, "off-target sites come first")
        let outside = report.sites.filter { $0.viewClass?.hasSuffix("OutsideView") == true }
        #expect(outside.reduce(0) { $0 + $1.count } == 2)
        #expect(outside.allSatisfy { $0.placement == "outside" && $0.turnKinds == ["key"] })
        #expect(Set(outside.flatMap(\.calls)) == ["view.needsDisplay", "view.needsUpdateConstraints"])
        #expect(Set(outside.flatMap(\.phases)) == ["dispatch", "commit"])
        let inside = try #require(report.sites.first { $0.viewClass?.hasSuffix("InsideView") == true })
        #expect(inside.placement == "inside")
        #expect(!inside.offTarget)
        #expect(inside.calls == ["view.needsLayout"])
        #expect(report.sites.allSatisfy { !$0.frames.isEmpty }, "every site keeps its stack")
        #expect(report.turns.closed == 1)
        #expect(report.turns.recent.first?.dirtyCalls == 3)
        #expect(report.turns.recent.first?.offTargetCalls == 2)
        #expect((report.turns.recent.first?.dispatchMs ?? 0) > 0)
        #expect((report.turns.recent.first?.commitMs ?? 0) > 0)
    }

    @Test func aLayerCallIsOwnedByTheViewItsLayerTreeBelongsTo() async throws {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        let views = tree()
        views.outside.wantsLayer = true
        let backing = try #require(views.outside.layer)
        let sublayer = CALayer()
        backing.addSublayer(sublayer)
        let loose = CALayer()
        recorder.beginDispatch(.pointer, target: views.target)
        sublayer.setNeedsLayout()
        loose.setNeedsDisplay()
        recorder.endDispatch()
        recorder.commitDidRun()
        let report = await recorder.report()
        let owned = try #require(report.sites.first { $0.calls == ["layer.setNeedsLayout"] })
        #expect(owned.viewClass?.hasSuffix("OutsideView") == true)
        #expect(owned.layerClass?.hasSuffix("CALayer") == true)
        #expect(owned.placement == "outside")
        let unowned = try #require(report.sites.first { $0.calls == ["layer.setNeedsDisplay"] })
        #expect(unowned.viewClass == nil)
        #expect(unowned.placement == "no_view")
    }

    @Test func aCallOffTheMainThreadPassesThrough() async {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        recorder.beginDispatch(.key, target: nil)
        await Task.detached(priority: .high) {
            let layer = OffMainLayer()
            layer.setNeedsLayout()
            layer.setNeedsDisplay()
        }.value
        recorder.endDispatch()
        recorder.commitDidRun()
        // Other suites' main-thread work may land in the turn while this one awaits: look for this layer only.
        let sites = await recorder.report().sites
        #expect(!sites.contains { $0.layerClass?.hasSuffix("OffMainLayer") == true })
    }

    @Test func sitesStopAtTheLimitAndLaterNewSitesOnlyCount() async {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        let owner = InputDirtyRecorder.Owner(viewClass: unsafeBitCast(OutsideView.self as AnyClass, to: UInt.self), layerClass: 0,
                                             placement: .outside)
        let extra = 44
        recorder.beginDispatch(.key, target: nil)
        for site in 0..<(InputDirtyRecorder.siteLimit + extra) {
            let stack: [UInt] = [UInt(site) + 1, 2, 3]
            stack.withUnsafeBufferPointer { recorder.record(.viewNeedsLayout, owner: owner, stack: $0) }
        }
        [UInt(1), 2, 3].withUnsafeBufferPointer { recorder.record(.viewNeedsLayout, owner: owner, stack: $0) }
        recorder.endDispatch()
        recorder.commitDidRun()
        let report = await recorder.report()
        #expect(report.sites.count == InputDirtyRecorder.siteLimit)
        #expect(report.droppedCalls == extra)
        #expect(report.dirtyCalls == InputDirtyRecorder.siteLimit + extra + 1)
        #expect(report.sites.first?.count == 2, "a known site still counts after the limit")
        #expect(await recorder.report(limit: 5).sites.count == 5)
    }

    @Test func turnsKeepTheNewestUpToTheLimitOldestFirst() async {
        let ticks = Ticks()
        let recorder = InputDirtyRecorder(now: { ticks.read() })
        recorder.install()
        defer { recorder.remove() }
        let closed = InputDirtyRecorder.turnLimit + 6
        for turn in 0..<closed {
            for _ in 0...turn {
                recorder.beginDispatch(.scroll, target: nil)
                recorder.endDispatch()
            }
            recorder.commitDidRun()
        }
        let turns = await recorder.report().turns
        #expect(turns.closed == closed)
        #expect(turns.kept == InputDirtyRecorder.turnLimit)
        #expect(turns.recent.map(\.events) == Array((closed - InputDirtyRecorder.turnLimit + 1)...closed))
        #expect(turns.recent.allSatisfy { $0.kinds == ["scroll"] })
    }

    @Test func aTurnStaysOpenWhileItsDispatchRuns() async {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        recorder.beginDispatch(.pointer, target: nil)
        recorder.commitDidRun() // a commit inside a nested tracking loop
        #expect(await recorder.report().turns.closed == 0)
        recorder.endDispatch()
        recorder.commitDidRun()
        #expect(await recorder.report().turns.closed == 1)
    }

    @Test func theReportEncodesItsSnakeCaseKeys() async throws {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        let report = await recorder.report()
        let data = try JSONEncoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["installed", "dirty_calls", "off_target_calls", "dropped_calls", "site_limit", "turns", "sites"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let turns = try #require(object["turns"] as? [String: Any])
        for key in ["closed", "kept", "dispatch_ms", "commit_ms", "recent"] {
            #expect(turns[key] != nil, "missing turns.\(key)")
        }
    }

    @Test func dispatchingWrapsAPersonsEventInATurnAndNoOtherEvent() async throws {
        let recorder = InputDirtyRecorder()
        recorder.install()
        defer { recorder.remove() }
        let view = OutsideView(frame: .zero)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                                keyCode: 0))
        let defined = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        var dispatched = 0
        recorder.dispatching(defined) {
            dispatched += 1
            view.needsLayout = true
        }
        recorder.commitDidRun()
        #expect(await recorder.report().turns.closed == 0, "an app-defined event is no input turn")
        recorder.dispatching(key) {
            dispatched += 1
            view.needsLayout = true
        }
        recorder.commitDidRun()
        #expect(dispatched == 2)
        let report = await recorder.report()
        #expect(report.turns.closed == 1)
        #expect(report.dirtyCalls == 1)
        #expect(report.sites.first?.placement == "no_target", "a key with no window has no target view")
    }

    @Test func onlyAPersonsInputOpensATurn() {
        #expect(InputDirtyRecorder.TurnKind(.keyDown) == .key)
        #expect(InputDirtyRecorder.TurnKind(.flagsChanged) == .key)
        #expect(InputDirtyRecorder.TurnKind(.leftMouseDragged) == .pointer)
        #expect(InputDirtyRecorder.TurnKind(.scrollWheel) == .scroll)
        #expect(InputDirtyRecorder.TurnKind(.magnify) == .gesture)
        #expect(InputDirtyRecorder.TurnKind(.applicationDefined) == nil)
        #expect(InputDirtyRecorder.TurnKind(.periodic) == nil)
        #expect(InputDirtyRecorder.TurnKind(.mouseEntered) == nil)
    }
}
#endif
