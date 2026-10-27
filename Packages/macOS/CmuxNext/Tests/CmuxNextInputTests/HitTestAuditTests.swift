import AppKit
import CmuxNextControl
import CmuxNextInput
@testable import CmuxNextInputDiagnostics
import CmuxNextSettings
import Foundation
import ObjectiveC
import Testing

/// HitTestAudit (p04-input-098): installed on request only, it records views visited and time per hit test, per
/// event and per `hitTest:` implementation, lists the costly ones in a stable JSON report, and uninstalled it leaves
/// every original IMP in place. One serialized suite: the hooks are process-wide.
@MainActor
@Suite(.serialized) struct HitTestAuditTests {
    #if DEBUG || CMUX_BENCH_HOOKS
    // Not final, and called through an `NSView` reference, so every call goes through Objective-C dispatch.
    class RootView: NSView {}
    class LeafView: NSView {}

    class SuperCallingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }
    }

    /// Each read advances by `step`, so every recorded time is a whole number of steps.
    final class StepClock {
        let step: UInt64
        private(set) var nanos: UInt64 = 0

        init(step: UInt64) { self.step = step }

        func read() -> UInt64 {
            nanos += step
            return nanos
        }
    }

    private static let step: UInt64 = 1_000

    private func audit(_ thresholds: HitTestAuditThresholds = HitTestAuditThresholds(),
                       input: InputEventTap? = nil) -> HitTestAudit {
        let clock = StepClock(step: Self.step)
        return HitTestAudit(
            input: input,
            thresholds: thresholds,
            onlyClasses: [NSView.self, SuperCallingView.self],
            now: { clock.read() }
        )
    }

    private func hitTestIMPs() -> [IMP?] {
        [NSView.self, SuperCallingView.self].map { class_getMethodImplementation($0, #selector(NSView.hitTest(_:))) }
    }

    /// A 100 x 100 root with three 10 x 10 leaves along its bottom edge.
    private func rootWithLeaves(_ root: NSView = RootView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))) -> NSView {
        for index in 0..<3 {
            root.addSubview(LeafView(frame: NSRect(x: CGFloat(index) * 20, y: 0, width: 10, height: 10)))
        }
        return root
    }

    /// The report of what is recorded now, built in the same main-actor turn: no other test's hit test (the hooks
    /// are process-wide) can land between the caller's own calls and this read.
    private func recorded(_ audit: HitTestAudit) -> HitTestAuditReport {
        HitTestAuditReport(snapshot: audit.snapshot(), thresholds: audit.thresholds)
    }

    private func row(_ report: HitTestAuditReport, _ type: AnyClass) -> HitTestAuditReport.Row? {
        report.rows.first { $0.className == HitTestAudit.name(of: type) }
    }

    /// Never installed, installed, uninstalled: the hooks are in only while installed, and calls outside an install
    /// record nothing.
    @Test func hooksOnlyWhileInstalled() async {
        let audit = audit()
        let originals = hitTestIMPs()
        let root = rootWithLeaves()
        _ = root.hitTest(NSPoint(x: 90, y: 90))
        #expect(audit.hookedImplementations == 0)
        #expect(await audit.report().hitTests.count == 0)

        #expect(await audit.install())
        #expect(audit.isInstalled)
        #expect(audit.hookedImplementations == 2)
        #expect(zip(hitTestIMPs(), originals).allSatisfy { $0 != $1 })

        await audit.uninstall()
        #expect(!audit.isInstalled)
        #expect(hitTestIMPs() == originals)
        audit.reset()
        _ = root.hitTest(NSPoint(x: 90, y: 90))
        let report = await audit.report()
        #expect(!report.installed)
        #expect(report.hookedImplementations == 0)
        #expect(report.hitTests.count == 0)
    }

    /// A miss under three leaves visits the root and every leaf: one hit test of 4 views; the root's row has the
    /// whole walk, each leaf one view.
    @Test func viewsVisitedAndTimePerHitTest() async {
        let audit = audit()
        #expect(await audit.install())
        audit.reset()
        let root = rootWithLeaves()
        #expect(root.hitTest(NSPoint(x: 90, y: 90)) === root)
        let report = recorded(audit)
        await audit.uninstall()

        #expect(report.hitTests.count == 1)
        #expect(report.hitTests.views.max == 4)
        // Root enter, three leaf enter and exit pairs, root exit: 7 steps.
        #expect(report.hitTests.ns.max == 7 * Self.step)
        let rootRow = row(report, RootView.self)
        #expect(rootRow?.calls == 1)
        #expect(rootRow?.views.p99 == 4)
        #expect(rootRow?.definesHitTest == false)
        let leafRow = row(report, LeafView.self)
        #expect(leafRow?.calls == 3)
        #expect(leafRow?.views.max == 1)
        #expect(leafRow?.ns.max == Self.step)
        #expect(report.rows.first?.className == HitTestAudit.name(of: RootView.self))
    }

    /// An override that calls `super` visits its view once, at the override's row.
    @Test func superCallIsOneVisit() async {
        let audit = audit()
        #expect(await audit.install())
        audit.reset()
        let root = SuperCallingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        root.addSubview(LeafView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        #expect((root as NSView).hitTest(NSPoint(x: 90, y: 90)) === root)
        let report = recorded(audit)
        await audit.uninstall()

        #expect(report.hitTests.count == 1)
        #expect(report.hitTests.views.max == 2)
        #expect(report.hitTests.ns.max == 3 * Self.step)
        let overrideRows = report.rows.filter { $0.className == HitTestAudit.name(of: SuperCallingView.self) }
        #expect(overrideRows.count == 1)
        #expect(overrideRows.first?.definesHitTest == true)
        #expect(overrideRows.first?.calls == 1)
    }

    /// Rows over either threshold are costly, with their reasons, and listed in row order.
    @Test func costlyRowsAreListed() async {
        let audit = audit(HitTestAuditThresholds(p99NanosOver: 2 * Self.step, p99ViewsOver: 3))
        #expect(await audit.install())
        audit.reset()
        _ = rootWithLeaves().hitTest(NSPoint(x: 90, y: 90))
        let report = recorded(audit)
        await audit.uninstall()

        #expect(report.costly == [HitTestAudit.name(of: RootView.self)])
        #expect(row(report, RootView.self)?.costly == [HitTestAuditReport.p99NanosReason, HitTestAuditReport.p99ViewsReason])
        #expect(row(report, LeafView.self)?.costly == [])
    }

    /// One tap dispatch is one event: it sums its hit tests, a nested dispatch joins it, and an event with none, or
    /// one while nothing is installed, is not recorded.
    @Test func timePerEvent() async throws {
        let tap = InputEventTap()
        let audit = audit(input: tap)
        let event = try Self.mouseDown()
        let root = rootWithLeaves()
        dispatch(event, on: tap) { _ = root.hitTest(NSPoint(x: 90, y: 90)) }
        #expect(await audit.install())
        audit.reset()
        dispatch(event, on: tap) {
            _ = root.hitTest(NSPoint(x: 90, y: 90))
            dispatch(event, on: tap) { _ = root.hitTest(NSPoint(x: 90, y: 90)) }
        }
        dispatch(event, on: tap) {}
        _ = root.hitTest(NSPoint(x: 90, y: 90))
        let report = recorded(audit)
        await audit.uninstall()

        #expect(report.hitTests.count == 3)
        #expect(report.events.count == 1)
        #expect(report.events.hitTests.max == 2)
        #expect(report.events.views.max == 8)
        #expect(report.events.ns.max == 14 * Self.step)
    }

    /// No cost off: never installed or uninstalled, the audit has no tap subscription and no hook.
    @Test func tapSubscriptionsOnlyWhileInstalled() async {
        let tap = InputEventTap()
        let audit = audit(input: tap)
        func subscribers() -> [Int] {
            [tap.subscriberCount(.button, stage: .observe), tap.subscriberCount(.button, stage: .dispatchEnd),
             tap.subscriberCount(.tracking, stage: .observe)]
        }
        #expect(subscribers() == [0, 0, 0])
        #expect(await audit.install())
        #expect(subscribers() == [1, 1, 1])
        await audit.uninstall()
        #expect(subscribers() == [0, 0, 0])
        #expect(audit.hookedImplementations == 0)
    }

    /// `debug.input hittest` installs on the first request and answers the cmux.hittest.v1 report; `reset`
    /// uninstalls.
    @Test func debugInputActionInstallsOnRequest() async throws {
        let audit = audit()
        let debugInput = DebugInput(sources: [], recorders: [HitTestAuditDebugRecorder(audit: audit)])
        #expect(!audit.isInstalled)
        let reply = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("hittest")]))
        #expect(audit.isInstalled)
        let data = try JSONSerialization.data(withJSONObject: reply.foundationObject)
        let report = try JSONDecoder().decode(HitTestAuditReport.self, from: data)
        #expect(report.schema == HitTestAuditReport.currentSchema)
        #expect(report.installed)
        #expect(report.hookedImplementations == 2)
        _ = try await debugInput.reply(to: .reset)
        #expect(!audit.isInstalled)
    }

    /// One event's dispatch through the tap's stages, as the application object runs it.
    private func dispatch(_ event: NSEvent, on tap: InputEventTap, _ body: () -> Void) {
        tap.dispatching {
            tap.deliverObserve(event)
            body()
            tap.deliverAfterDispatch(event)
        }
        tap.deliverDispatchEnd(event, outcome: .delivered)
    }

    private static func mouseDown() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The JSON has a fixed key set, sorted keys and the same bytes for the same report, and decodes back.
    @Test func stableJSON() async throws {
        let audit = audit()
        #expect(await audit.install())
        audit.reset()
        _ = rootWithLeaves().hitTest(NSPoint(x: 90, y: 90))
        let report = recorded(audit)
        await audit.uninstall()

        let data = try report.jsonData()
        #expect(try report.jsonData() == data)
        #expect(try JSONDecoder().decode(HitTestAuditReport.self, from: data) == report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "available", "costly", "events", "hit_tests", "hooked_implementations", "installed", "rows", "schema",
            "thresholds",
        ])
        #expect(object["schema"] as? String == HitTestAuditReport.currentSchema)
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(rows.allSatisfy { Set($0.keys) == ["calls", "class", "costly", "ns", "override", "sampled", "views"] })
        let events = try #require(object["events"] as? [String: Any])
        #expect(Set(events.keys) == ["count", "hit_tests", "ns", "sampled", "views"])
        let thresholds = try #require(object["thresholds"] as? [String: Any])
        #expect(Set(thresholds.keys) == ["p99_ns_over", "p99_views_over"])
        let ns = try #require(rows.first?["ns"] as? [String: Any])
        #expect(Set(ns.keys) == ["max", "p50", "p95", "p99"])
    }

    /// The full scan finds NSView's own `hitTest:` and each subclass that defines one, never one that inherits it.
    @Test func scanFindsOverrides() async {
        let definers = await HitTestAudit.scanDefiners(onlyClassKeys: nil)
        let keys = Set(definers.map(\.key))
        func key(_ type: AnyClass) -> UInt { unsafeBitCast(type, to: UInt.self) }
        #expect(keys.contains(key(NSView.self)))
        #expect(keys.contains(key(SuperCallingView.self)))
        #expect(!keys.contains(key(LeafView.self)))
        #expect(!keys.contains(key(NSObject.self)))
    }

    /// Reset clears the samples and keeps the hooks.
    @Test func resetKeepsHooks() async {
        let audit = audit()
        #expect(await audit.install())
        let root = rootWithLeaves()
        audit.reset()
        _ = root.hitTest(NSPoint(x: 90, y: 90))
        #expect(recorded(audit).hitTests.count == 1)
        audit.reset()
        #expect(recorded(audit).hitTests.count == 0)
        #expect(audit.isInstalled)
        _ = root.hitTest(NSPoint(x: 90, y: 90))
        #expect(recorded(audit).hitTests.count == 1)
        await audit.uninstall()
    }
    #else
    /// A build without hooks never installs.
    @Test func noHooksInThisBuild() async {
        let audit = HitTestAudit(input: InputEventTap())
        #expect(!HitTestAudit.isAvailable)
        #expect(!(await audit.install()))
        #expect(!(await audit.report().available))
    }
    #endif

    /// Nearest-rank percentiles; all 0 with no samples.
    @Test func distribution() {
        let distribution = HitTestAuditReport.Distribution(Array(1...100).reversed().map { UInt64($0) })
        #expect(distribution.p50 == 50)
        #expect(distribution.p95 == 95)
        #expect(distribution.p99 == 99)
        #expect(distribution.max == 100)
        #expect(HitTestAuditReport.Distribution([]) == HitTestAuditReport.Distribution([0]))
    }

    /// The ring keeps the last `capacity` samples and counts every one.
    @Test func ringKeepsTheMostRecent() {
        var ring = HitTestAuditSampleRing(capacity: 4)
        for value in 1...6 { ring.add(nanos: UInt64(value), views: UInt32(value), hitTests: 1) }
        let samples = ring.samples()
        #expect(samples.calls == 6)
        #expect(samples.nanos.sorted() == [3, 4, 5, 6])
        #expect(samples.views.sorted() == [3, 4, 5, 6])
        ring.clear()
        #expect(ring.samples().calls == 0)
        #expect(ring.samples().nanos.isEmpty)
    }
}
