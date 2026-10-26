import AppKit
import Testing
@testable import MessagesLabHome

/// The appkit-port and appkit-native seams of p10-stability-042: main-actor observers and timers
/// for the vendored views, the spell check routed through its field, the renderer's own color
/// space, and the effect view that makes no AppKit view.
@MainActor @Suite(.serialized) struct AppKitPortConcurrencyTests {
    /// A counter the main-actor handlers bump (a captured `var` cannot cross into a Sendable closure).
    private final class Count { var n = 0 }

    /// A post on the main thread runs the handler inline, in the poster's turn (as the views'
    /// `.main` block observers did); the observer is gone with its object.
    @Test func aMainQueueObservationRunsInlineAndEndsWithItsObject() {
        let center = NotificationCenter()
        let name = Notification.Name("AppKitPortConcurrencyTests.post")
        let seen = Count()
        var observation: MainQueueObservation? = MainQueueObservation(name, object: nil, center: center) { _ in seen.n += 1 }
        center.post(name: name, object: nil)
        #expect(seen.n == 1)
        _ = observation
        observation = nil
        center.post(name: name, object: nil)
        #expect(seen.n == 1)
    }

    /// The timer fires once on the main run loop; an invalidated one never fires.
    @Test func aMainRunLoopTimerFiresOnceAndAnInvalidatedOneNever() {
        let fired = Count(), cancelledFired = Count()
        let cancelled = MainRunLoopTimer(after: 0) { cancelledFired.n += 1 }
        cancelled.invalidate()
        let timer = MainRunLoopTimer(after: 0.01) { fired.n += 1 }
        #expect(timer.isValid)
        // The main run loop in its default mode, as AppKit runs it between events (bounded).
        let deadline = Date(timeIntervalSinceNow: 2)
        while fired.n == 0, Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(fired.n == 1)
        #expect(!timer.isValid)
        #expect(cancelledFired.n == 0)
        #expect(!cancelled.isValid)
    }

    /// The renderer draws in its format's color space, so a render job off main can take the space
    /// its request read on main instead of the process-wide one main may replace meanwhile.
    @Test func theRendererDrawsInItsFormatsColorSpace() {
        let process = DisplayScale.colorSpace
        defer { DisplayScale.colorSpace = process }
        DisplayScale.colorSpace = LabColorSpace.sRGB
        let format = UIGraphicsImageRendererFormat()
        #expect(format.colorSpace.name.map { $0 as String } == CGColorSpace.sRGB as String)
        format.colorSpace = LabColorSpace.displayP3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        #expect(image.cgImage?.colorSpace?.name.map { $0 as String } == CGColorSpace.displayP3 as String)
    }

    /// A draft the compose bar replaces (no `didChangeText`) is spell checked on the next main turn,
    /// through the field's own checker (main actor).
    @Test func aReplacedDraftIsSpellCheckedOnTheNextTurn() async {
        let field = FieldTextView(usingTextLayoutManager: true)
        field.string = "helo wrold"
        let before = DeferredSpellChecker.checks
        field.textReplaced()
        #expect(DeferredSpellChecker.checks == before)  // coalesced to the next turn, not on the keystroke frame
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // main-async-allow: one GCD main-queue turn, the turn DeferredSpellChecker.schedule() posts its check to
            DispatchQueue.main.async { done.resume() }
        }
        #expect(DeferredSpellChecker.checks > before)  // other suites' fields may check in the same turn
    }

    /// The shim's effect view keeps the material only: no AppKit view is made for it off the main actor.
    @Test func theEffectViewKeepsItsMaterial() {
        #expect(UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark)).material == .headerView)
        #expect(UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark)).material == .hudWindow)
    }
}
