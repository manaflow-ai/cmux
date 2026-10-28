#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextControl
import CmuxNextInput
@testable import CmuxNextInputDiagnostics
import ObjectiveC
import QuartzCore
import Testing

private final class DirtyContainerView: NSView {}
private final class DirtyTargetView: NSView {}
private final class DirtyChildView: NSView {}
private final class DirtyOutsideView: NSView {}
private final class DirtyLateView: NSView {}

/// A clock the test moves.
@MainActor
private final class DirtyClock {
    var nanos: UInt64 = 0
}

/// `debug.input` action `dirty`: the first request installs the hooks, the tap
/// subscription and the run-loop observers and `reset` removes them all; a dirty call in an input turn
/// counts under its view's relation to the target, off-target rows first; calls outside a turn and
/// calls inside another hooked call do not count; a pass inside the event's dispatch (a tracking loop)
/// does not end the turn; sites and turns stay bounded; the reply encodes.
/// Serialized: the hooks replace NSView's and CALayer's methods for the whole process.
@MainActor @Suite(.serialized)
struct InputDirtyRecorderTests {
    /// A window: a container (content view) holding the target, its child, and a view beside it.
    private struct Views {
        let window: NSWindow
        let container: DirtyContainerView
        let target: DirtyTargetView
        let child: DirtyChildView
        let outside: DirtyOutsideView
        let late: DirtyLateView
    }

    private func makeViews() -> Views {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = DirtyContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.wantsLayer = true
        let target = DirtyTargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let child = DirtyChildView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        let outside = DirtyOutsideView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        let late = DirtyLateView(frame: NSRect(x: 300, y: 0, width: 50, height: 50))
        target.addSubview(child)
        container.addSubview(target)
        container.addSubview(outside)
        container.addSubview(late)
        window.contentView = container
        return Views(window: window, container: container, target: target, child: child, outside: outside, late: late)
    }

    private func makeRecorder(_ ledger: InputDirtyLedger) -> InputDirtyRecorder {
        InputDirtyRecorder(ledger: ledger) { copy in await copy() }
    }

    private func implementations() -> [InputDirtyCall: IMP] {
        var found: [InputDirtyCall: IMP] = [:]
        for call in InputDirtyCall.allCases {
            if let method = class_getInstanceMethod(call.root, call.selector) { found[call] = method_getImplementation(method) }
        }
        return found
    }

    @Test func theFirstRequestInstallsAndResetRemoves() async {
        let tap = InputEventTap()
        let ledger = InputDirtyLedger(tap: tap)
        let recorder = makeRecorder(ledger)
        let originals = implementations()
        #expect(originals.count == InputDirtyCall.allCases.count, "every hooked method exists")
        #expect(tap.subscriberCount(.key, stage: .observe) == 0)

        let first = await recorder.rows(sinceLaunch: false)
        #expect(first.installed && first.installedNow && first.rows.isEmpty)
        #expect(ledger.isInstalled)
        let installed = implementations()
        for call in InputDirtyCall.allCases {
            #expect(installed[call] != originals[call], "\(call.name) is hooked")
        }
        for eventClass in [InputEventClass.key, .button, .scroll] {
            #expect(tap.subscriberCount(eventClass, stage: .observe) == 1, "\(eventClass) starts turns")
            #expect(tap.subscriberCount(eventClass, stage: .dispatchEnd) == 1, "\(eventClass)'s dispatch end lets a pass end the turn")
        }

        let second = await recorder.rows(sinceLaunch: false)
        #expect(second.installed && !second.installedNow, "a second request reads, it does not install again")
        #expect(implementations() == installed)

        await recorder.reset()
        #expect(!ledger.isInstalled)
        #expect(implementations() == originals, "reset gives every method its own implementation back")
        #expect(tap.subscriberCount(.key, stage: .observe) == 0)
        #expect(tap.subscriberCount(.key, stage: .dispatchEnd) == 0)

        let again = await recorder.rows(sinceLaunch: false)
        #expect(again.installedNow, "a request after reset installs again")
        await recorder.reset()
        #expect(implementations() == originals)
    }

    @Test func offTargetViewsAreListedFirst() async throws {
        let clock = DirtyClock()
        let ledger = InputDirtyLedger(tap: InputEventTap()) { clock.nanos }
        let recorder = makeRecorder(ledger)
        _ = await recorder.rows(sinceLaunch: false)
        let views = makeViews()
        let sublayer = CALayer()
        views.outside.wantsLayer = true
        try #require(views.outside.layer).addSublayer(sublayer)

        views.child.needsDisplay = true  // before any turn: not counted
        ledger.began(.key, target: views.target)
        views.child.needsDisplay = true
        views.child.needsDisplay = false  // a false flag dirties nothing
        views.outside.needsLayout = true
        views.container.needsUpdateConstraints = true
        sublayer.setNeedsDisplay()
        ledger.dispatchEnded()
        clock.nanos = 1_000_000
        ledger.passBegan()
        clock.nanos = 3_500_000
        ledger.passEnded()
        views.late.needsDisplay = true  // after the turn's commit pass: not counted

        let reply = await recorder.rows(sinceLaunch: false)
        await recorder.reset()
        let rows = reply.rows
        let child = try #require(rows.first { $0.objectClass == "DirtyChildView" && $0.call == "view.needs_display" })
        #expect(child.relation == "target" && !child.offTarget && child.count == 1 && child.kinds == ["key"])
        let outside = try #require(rows.first { $0.objectClass == "DirtyOutsideView" && $0.call == "view.needs_layout" })
        #expect(outside.relation == "outside" && outside.offTarget)
        let container = try #require(rows.first { $0.objectClass == "DirtyContainerView" && $0.call == "view.needs_update_constraints" })
        #expect(container.relation == "ancestor" && !container.offTarget)
        let layer = try #require(rows.first { $0.call == "layer.needs_display" && $0.viewClass == "DirtyOutsideView" })
        #expect(layer.relation == "outside" && layer.offTarget && layer.objectClass == "CALayer")
        #expect(!rows.contains { $0.objectClass == "DirtyLateView" }, "a call after the turn ended is not counted")
        #expect(rows.first?.offTarget == true, "off-target rows come first")
        #expect(!child.stack.isEmpty, "the site keeps its stack")
        #expect(reply.turns == ["key": 1])
        #expect(reply.offTargetCalls >= 2)
        let pass = try #require(reply.commitPass["key"])
        #expect(pass.n == 1 && pass.max == 2.5, "the commit pass that ended the turn, in ms")
        #expect(reply.callsPerTurn["key"]?.max == Double(reply.calls))
    }

    @Test func sitesAndTurnsAreBounded() async {
        let ledger = InputDirtyLedger(tap: InputEventTap(), siteLimit: 2, turnLimit: 2) { 0 }
        let recorder = makeRecorder(ledger)
        _ = await recorder.rows(sinceLaunch: false)
        let views = makeViews()
        for _ in 0..<3 {
            ledger.began(.click, target: views.target)
            views.child.needsDisplay = true
            views.outside.needsDisplay = true
            views.late.needsDisplay = true
            ledger.dispatchEnded()
            ledger.passBegan()
            ledger.passEnded()
        }
        let reply = await recorder.rows(sinceLaunch: false)
        await recorder.reset()
        #expect(reply.rows.count == 2 && reply.siteLimit == 2)
        #expect(reply.sitesOverflow == 3, "the third site's call in each turn overflows")
        #expect(reply.turns == ["click": 3])
        #expect(reply.commitPass["click"]?.n == 2, "the distributions keep the newest turns only")
    }

    @Test func sinceLaunchOutlivesReset() async {
        let ledger = InputDirtyLedger(tap: InputEventTap()) { 0 }
        let recorder = makeRecorder(ledger)
        _ = await recorder.rows(sinceLaunch: false)
        let views = makeViews()
        ledger.began(.scroll, target: views.target)
        views.outside.needsDisplay = true
        ledger.dispatchEnded()
        ledger.passBegan()
        ledger.passEnded()
        await recorder.reset()
        let launch = await recorder.rows(sinceLaunch: true)
        let sinceReset = await recorder.rows(sinceLaunch: false)
        await recorder.reset()
        #expect(launch.sinceLaunch && launch.rows.contains { $0.objectClass == "DirtyOutsideView" && $0.kinds == ["scroll"] })
        #expect(sinceReset.rows.isEmpty && sinceReset.turns.isEmpty)
    }

    /// A click on a control runs a tracking loop inside `sendEvent`: its run-loop passes come before the
    /// control's action, so they must not end the turn. The first pass after the dispatch returns does.
    @Test func aPassInsideTheDispatchDoesNotEndTheTurn() async throws {
        let clock = DirtyClock()
        let ledger = InputDirtyLedger(tap: InputEventTap()) { clock.nanos }
        let recorder = makeRecorder(ledger)
        _ = await recorder.rows(sinceLaunch: false)
        let views = makeViews()

        ledger.began(.click, target: views.target)
        clock.nanos = 1_000_000
        ledger.passBegan()  // the tracking loop's pass, inside the dispatch
        clock.nanos = 9_000_000
        ledger.passEnded()
        views.outside.needsDisplay = true  // the control's action, after the tracking loop: counted
        ledger.began(.click, target: views.target)  // an event the tracking loop sends on: one more open dispatch
        ledger.dispatchEnded()
        ledger.passBegan()
        ledger.passEnded()  // the outer dispatch is still open
        views.child.needsDisplay = true
        ledger.dispatchEnded()
        clock.nanos = 10_000_000
        ledger.passBegan()
        clock.nanos = 12_000_000
        ledger.passEnded()
        views.late.needsDisplay = true  // after the commit pass: not counted

        let reply = await recorder.rows(sinceLaunch: false)
        await recorder.reset()
        #expect(reply.turns == ["click": 1], "the passes inside the dispatch ended no turn")
        #expect(reply.rows.contains { $0.objectClass == "DirtyOutsideView" && $0.offTarget && $0.kinds == ["click"] })
        #expect(reply.rows.contains { $0.objectClass == "DirtyChildView" && $0.relation == "target" })
        #expect(!reply.rows.contains { $0.objectClass == "DirtyLateView" })
        let pass = try #require(reply.commitPass["click"])
        #expect(pass.n == 1 && pass.max == 2, "the commit pass after the dispatch, not the tracking loop's, in ms")
        #expect(reply.calls >= 2 && reply.callsPerTurn["click"]?.max == Double(reply.calls), "one turn holds every counted call")
    }

    @Test func aDispatchEndWithNoOpenDispatchDoesNothing() async {
        let ledger = InputDirtyLedger(tap: InputEventTap()) { 0 }
        let recorder = makeRecorder(ledger)
        _ = await recorder.rows(sinceLaunch: false)
        ledger.dispatchEnded()  // installed inside a dispatch: its end has no turn
        ledger.began(.key, target: nil)
        ledger.passBegan()
        ledger.passEnded()
        let open = await recorder.rows(sinceLaunch: false)
        ledger.dispatchEnded()
        ledger.dispatchEnded()  // a second end does not reopen or underflow
        ledger.passBegan()
        ledger.passEnded()
        let ended = await recorder.rows(sinceLaunch: false)
        await recorder.reset()
        #expect(open.turns.isEmpty, "the key's dispatch is still open")
        #expect(ended.turns == ["key": 1])
    }

    @Test func aTurnNeedsTheRecorderInstalled() {
        let ledger = InputDirtyLedger(tap: InputEventTap()) { 0 }
        let views = makeViews()
        ledger.began(.key, target: views.target)
        ledger.dispatchEnded()
        ledger.passBegan()
        ledger.passEnded()
        let copy = ledger.request(sinceLaunch: true)
        _ = ledger.remove()
        #expect(copy.window.turns.isEmpty, "no turn starts before the recorder is installed")
    }

    @Test func relations() throws {
        let views = makeViews()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let elsewhere = NSView()
        other.contentView = elsewhere
        #expect(InputDirtyRelation(of: views.target, to: views.target) == .target)
        #expect(InputDirtyRelation(of: views.child, to: views.target) == .target)
        #expect(InputDirtyRelation(of: views.container, to: views.target) == .ancestor)
        #expect(InputDirtyRelation(of: views.outside, to: views.target) == .outside)
        #expect(InputDirtyRelation(of: elsewhere, to: views.target) == .otherWindow)
        #expect(InputDirtyRelation(of: nil, to: views.target) == .noView)
        #expect(InputDirtyRelation(of: views.outside, to: nil) == .noTarget)
        let hosted = CALayer()
        try #require(views.container.layer).addSublayer(hosted)
        #expect(InputDirtyLedger.hostingView(of: hosted) === views.container)
        #expect(InputDirtyLedger.hostingView(of: CALayer()) == nil)
    }

    @Test func theReplyEncodesThroughDebugInput() async throws {
        let ledger = InputDirtyLedger(tap: InputEventTap()) { 0 }
        let debugInput = DebugInput(sources: [], recorders: [makeRecorder(ledger)])
        let reply = try await debugInput.reply(to: .record(.dirty, sinceLaunch: false))
        _ = try await debugInput.reply(to: .reset)
        #expect(!ledger.isInstalled, "debug.input reset removes the recorder")
        guard case .object(let members) = reply else {
            Issue.record("dirty did not answer an object: \(reply)")
            return
        }
        for key in ["installed", "installed_now", "since_launch", "turns", "calls", "off_target_calls", "sites_overflow",
                    "site_limit", "commit_pass_ms", "calls_per_turn", "turn_limit", "rows"] {
            #expect(members[key] != nil, "the reply has \(key)")
        }
    }
}
#endif
