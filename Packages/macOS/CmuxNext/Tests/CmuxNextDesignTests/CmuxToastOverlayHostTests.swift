import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// Toasts are native views on their window's overlay again (Lawrence 2026-11-10: "move toasts back
/// to swift ... with proper liquid glass"): `CmuxToastOverlayHost` draws what `CmuxToastCenter`
/// says, on the toast role's glass, bottom-center, the newest lowest, clear of the views toasts
/// avoid (the agent chat's composer, #37545), with their Undo, Details and close buttons.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct CmuxToastOverlayHostTests {
    private static func window(height: CGFloat = 400) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height), styleMask: [.borderless],
                 backing: .buffered, defer: false)
    }

    /// Closes `window` and its overlay panel (a child window the toasts live in).
    private static func close(_ window: NSWindow) {
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.closeAfterTest()
        panel?.close()
    }

    /// The toast views shown over `window`: they live in its overlay panel.
    private static func toastViews(in window: NSWindow) -> [CmuxToastView] {
        var found: [CmuxToastView] = []
        var pending: [NSView] = WindowOverlayHost.host(for: window).panel.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let toast = view as? CmuxToastView { found.append(toast) } else { pending.append(contentsOf: view.subviews) }
        }
        return found
    }

    private static func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    // MARK: Where toasts rest (pure)

    /// Where the window overlay draws a toast of `size` at `anchor`.
    private static func placed(_ size: NSSize, at anchor: NSRect, in bounds: NSRect) -> NSRect {
        NSRect(origin: WindowOverlayHost.origin(for: size, options: OverlayOptions(kind: .toast, anchor: anchor), in: bounds), size: size)
    }

    /// Bottom-center of the window, a margin above the content's bottom edge; the newest lowest,
    /// each older one above it by the real height of the ones below, a gap apart.
    @Test func theStackRestsBottomCenterWithTheNewestLowest() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let sizes = [NSSize(width: 260, height: 36), NSSize(width: 300, height: 120), NSSize(width: 240, height: 36)]
        let anchors = CmuxToastOverlayHost.anchors(sizes: sizes, in: bounds) { _ in bounds.minY }
        let frames = zip(sizes, anchors).map { Self.placed($0, at: $1, in: bounds) }
        #expect(frames.count == 3)
        let newest = frames[2], middle = frames[1], oldest = frames[0]
        #expect(newest.minY == bounds.minY + CmuxToastOverlayHost.overlayLift)
        #expect(middle.minY == newest.maxY + CmuxToastOverlayHost.stackGap)
        #expect(oldest.minY == middle.maxY + CmuxToastOverlayHost.stackGap, "the oldest does not stack on the tall toast's real height")
        for frame in frames { #expect(abs(frame.midX - bounds.midX) < 0.5) }
    }

    /// A floor (the top of an avoided box plus its gap) is the lowest bottom edge of every toast
    /// that it is under; a floor below the usual lift changes nothing.
    @Test(arguments: [CGFloat(0), 10, 24, 68, 300])
    func theStackRestsAtOrAboveItsFloor(floor: CGFloat) {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let sizes = [NSSize(width: 260, height: 36), NSSize(width: 260, height: 36)]
        let anchors = CmuxToastOverlayHost.anchors(sizes: sizes, in: bounds) { _ in floor }
        let frames = zip(sizes, anchors).map { Self.placed($0, at: $1, in: bounds) }
        let lowest = max(floor, bounds.minY + CmuxToastOverlayHost.overlayLift)
        #expect(frames[1].minY == lowest)
        #expect(frames[0].minY == lowest + 36 + CmuxToastOverlayHost.stackGap)
    }

    /// Each toast takes the floor of its own width: a narrow toast beside an avoided box stays
    /// low while a wide one over the box rests above it, still above the narrow one.
    @Test func eachToastTakesTheFloorOfItsOwnWidth() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let sizes = [NSSize(width: 500, height: 36), NSSize(width: 200, height: 36)]
        let anchors = CmuxToastOverlayHost.anchors(sizes: sizes, in: bounds) { $0 > 400 ? 200 : 0 }
        let frames = zip(sizes, anchors).map { Self.placed($0, at: $1, in: bounds) }
        #expect(frames[1].minY == bounds.minY + CmuxToastOverlayHost.overlayLift)
        #expect(frames[0].minY >= 200)
        #expect(frames[0].minY >= frames[1].maxY + CmuxToastOverlayHost.stackGap)
    }

    // MARK: Drawn natively

    /// A toast shows as a native view on the window's overlay, bottom-center, on the toast role's
    /// glass in this Mac's material: Liquid Glass where this Mac has it, never forced to the blur.
    @Test func aToastIsANativeViewOnThisMacsGlass() throws {
        let transparency = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let center = CmuxToastCenter(host: CmuxToastOverlayHost(reduceTransparency: transparency))
        let window = Self.window()
        defer { Self.close(window) }
        let handle = center.show(CmuxToast(id: "saved", message: "Saved"), in: window)
        let views = Self.toastViews(in: window)
        #expect(views.count == 1)
        let view = try #require(views.first)
        #expect(view.messageLabel?.stringValue == "Saved")
        let frame = Self.frame(view)
        #expect(abs(frame.midX - 300) < 1)
        #expect(abs(frame.minY - (CmuxToastOverlayHost.overlayLift)) < 0.5)
        let surface = try #require(view.surface)
        #expect(surface.material == OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable, reduceTransparency: false))
        #expect(!surface.prefersBlurToLiquidGlass, "the toast gives up Liquid Glass for the blur")
        #expect(surface.tone == SurfaceRole.toast.tone)
        #expect(surface.rimView != nil)
        #expect(surface.cornerRadius == SurfaceRole.toast.cornerRadius)
        handle.dismiss()
    }

    /// Under Reduce Transparency the toast is the opaque theme surface, with no rim.
    @Test func reduceTransparencyMakesTheToastOpaque() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo()), reduceTransparency: .alwaysOpaque)
        let surface = try #require(view.surface)
        #expect(surface.material == .opaque)
        #expect(surface.rimView == nil)
    }

    // MARK: Buttons

    /// A click on Undo runs the toast's action once and ends the toast.
    @Test func theUndoButtonRunsTheActionAndEndsTheToast() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let handle = center.show(CmuxToast(id: "closed", message: "Closed “New Tab”", action: .undo(), duration: CmuxToast.untilClosed), in: window)
        var ran = 0
        var reasons: [CmuxToastDismissReason] = []
        handle.onAction = { ran += 1 }
        handle.onDismiss = { reasons.append($0) }
        let view = try #require(Self.toastViews(in: window).first)
        let button = try #require(view.actionButton)
        #expect(button.accessibilityLabel() == CmuxToastStrings.undo)

        button.performClick(nil)
        #expect(ran == 1)
        #expect(reasons == [.action])
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.toastFrames(in: window).isEmpty)
        button.performClick(nil)
        #expect(ran == 1, "a toast that ended ran its action again")
    }

    /// The close button is where a click lands (nothing of the toast covers it), and a click on it
    /// ends the toast as closed by the person.
    @Test func theCloseButtonTakesTheClickAndEndsTheToast() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let handle = center.show(CmuxToast(id: "saved", message: "Saved", action: .undo(), duration: CmuxToast.untilClosed), in: window)
        var reasons: [CmuxToastDismissReason] = []
        handle.onDismiss = { reasons.append($0) }
        let view = try #require(Self.toastViews(in: window).first)
        view.layoutSubtreeIfNeeded()
        let close = view.closeButton
        #expect(close.frame.width >= CmuxToastButton.closeSide - 0.5 && close.frame.height >= CmuxToastButton.closeSide - 0.5)
        let holder = try #require(view.superview)
        let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: holder)
        let hit = try #require(view.hitTest(point), "a click on the close button reaches nothing")
        #expect(hit === close || hit.isDescendant(of: close), "a click on the close button lands on \(type(of: hit))")

        close.performClick(nil)
        #expect(reasons == [.closed])
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.toastFrames(in: window).isEmpty)
    }

    /// Details shows the detail in the toast itself, which grows up from its bottom edge; again, it
    /// hides it. The center owns the state; the button only reports the click.
    @Test func theDetailsButtonShowsAndHidesTheDetailInPlace() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window(height: 800)
        defer { Self.close(window) }
        let handle = center.show(CmuxToast(id: "update", message: "Couldn't update lab-mini", detail: "Bootstrap failed: 125",
                                           action: .details("Details"), duration: CmuxToast.untilClosed), in: window)
        let view = try #require(Self.toastViews(in: window).first)
        let button = try #require(view.actionButton)
        let closed = Self.frame(view)
        #expect(!view.showsDetails)

        button.performClick(nil)
        #expect(view.showsDetails && center.showsDetails(serial: handle.serial))
        #expect(view.detailLabel?.isHidden == false)
        #expect(button.accessibilityLabel() == CmuxToastStrings.hideDetails)
        let open = Self.frame(view)
        #expect(open.height > closed.height + 8, "the toast did not grow to show its detail")
        #expect(abs(open.minY - (closed.minY)) < 0.5, "the toast did not grow up from its bottom edge")
        #expect(!handle.isDismissed)

        button.performClick(nil)
        #expect(!view.showsDetails && !center.showsDetails(serial: handle.serial))
        #expect(abs(Self.frame(view).height - closed.height) < 0.5)
        handle.dismiss()
    }

    /// Cmd-Z runs the newest undo toast only: only its Undo button says so.
    @Test func onlyTheNewestUndoToastShowsTheKey() throws {
        let center = CmuxToastCenter(host: CmuxToastOverlayHost())
        let window = Self.window()
        defer { Self.close(window) }
        let first = center.show(CmuxToast(id: "a", message: "Closed A", action: .undo(), duration: CmuxToast.untilClosed), in: window)
        let second = center.show(CmuxToast(id: "b", message: "Closed B", action: .undo(), duration: CmuxToast.untilClosed), in: window)
        let views = Self.toastViews(in: window)
        let older = try #require(views.first { $0.toast.id == "a" }), newer = try #require(views.first { $0.toast.id == "b" })
        #expect(newer.showsUndoKey && !older.showsUndoKey)
        second.dismiss()
        #expect(older.showsUndoKey, "the undo key did not move to the toast that is the newest now")
        first.dismiss()
    }

    // MARK: Stacking and ending

    /// Three toasts stack clear of each other, the newest lowest; a fourth pushes the oldest out.
    @Test func toastsStackAndTheOldestGoesOverTheLimit() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let handles = (1...3).map { center.show(CmuxToast(id: "t\($0)", message: "Toast \($0)", duration: CmuxToast.untilClosed), in: window) }
        let frames = host.toastFrames(in: window)
        #expect(frames.count == 3)
        #expect(abs(frames[2].minY - (CmuxToastOverlayHost.overlayLift)) < 0.5)
        #expect(abs(frames[1].minY - (frames[2].maxY + CmuxToastOverlayHost.stackGap)) < 0.5)
        #expect(abs(frames[0].minY - (frames[1].maxY + CmuxToastOverlayHost.stackGap)) < 0.5)

        let fourth = center.show(CmuxToast(id: "t4", message: "Toast 4", duration: CmuxToast.untilClosed), in: window)
        #expect(handles[0].isDismissed)
        let after = host.toastFrames(in: window)
        #expect(after.count == CmuxToastStack.limit)
        #expect(abs(after[2].minY - (CmuxToastOverlayHost.overlayLift)) < 0.5)
        // The one pushed out fades clear of every toast that stays.
        let staying = Set(["t2", "t3", "t4"])
        let leaving = Self.toastViews(in: window).filter { !staying.contains($0.toast.id) }.map { Self.frame($0) }
        for frame in after { for gone in leaving { #expect(!frame.intersects(gone), "\(frame) overlaps the leaving toast \(gone)") } }
        (handles + [fourth]).forEach { $0.dismiss() }
        #expect(host.toastFrames(in: window).isEmpty)
    }

    /// A repeated toast (the same refusal again) takes the shown one's place: one toast, where it was.
    @Test func aSameIdToastTakesTheShownOnesPlace() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let first = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        let before = host.toastFrames(in: window)
        let second = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        #expect(first.isDismissed)
        #expect(host.toastFrames(in: window) == before)
        second.dismiss()
    }

    /// A toast ends when its time runs out, and its drawing goes with it.
    @Test(.timeLimit(.minutes(1))) func aToastEndsAfterItsTime() async throws {
        let host = CmuxToastOverlayHost()
        let clock = ManualClock()
        let center = CmuxToastCenter(clock: clock, host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let handle = center.show(CmuxToast(id: "saved", message: "Saved", duration: .seconds(6)), in: window)
        let dismissed = AsyncStream.makeStream(of: CmuxToastDismissReason.self)
        handle.onDismiss = { dismissed.continuation.yield($0) }
        #expect(host.toastFrames(in: window).count == 1)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(6))
        for await reason in dismissed.stream {
            #expect(reason == .timeout)
            break
        }
        #expect(host.toastFrames(in: window).isEmpty)
        #expect(center.toasts(in: window).isEmpty)
    }

    /// A window that closes ends its toasts.
    @Test func aClosedWindowEndsItsToasts() {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        let handle = center.show(CmuxToast(id: "saved", message: "Saved", duration: CmuxToast.untilClosed), in: window)
        var reasons: [CmuxToastDismissReason] = []
        handle.onDismiss = { reasons.append($0) }
        WindowOverlayHost.host(for: window).presentedHandles.forEach { $0.dismiss() }
        Self.close(window)
        #expect(reasons == [.closed])
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.toastFrames(in: window).isEmpty)
    }

    // MARK: Avoiding and reserving

    /// A toast rests above the composer it avoids, and the composer never moves for it; when the
    /// composer grows, the shown toast moves up clear of it (#37545).
    @Test func toastsLiftAboveAnAvoidedViewThatNeverMoves() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        try #require(window.contentView).addSubview(composer)
        let handles = [center.show(CmuxToast(id: "a", message: "Saved", duration: CmuxToast.untilClosed), in: window),
                       center.show(CmuxToast(id: "b", message: "Copied", duration: CmuxToast.untilClosed), in: window)]
        let gap = CmuxToastAvoidance.avoidanceGap
        var frames = host.toastFrames(in: window)
        #expect(frames.count == 2)
        #expect(abs(frames[1].minY - (60 + gap)) < 0.5, "the newest toast covers the composer")
        #expect(abs(frames[0].minY - (frames[1].maxY + CmuxToastOverlayHost.stackGap)) < 0.5)
        #expect(composer.frame == NSRect(x: 100, y: 0, width: 400, height: 60), "the composer moved for a toast")

        composer.frame.size.height = 160
        // What `CmuxToastAvoidance.avoidanceChanged(in:)` runs a turn later, here in the same turn.
        host.reanchor(in: window)
        frames = host.toastFrames(in: window)
        #expect(abs(frames[1].minY - (160 + gap)) < 0.5, "the toast stayed over the grown composer")
        #expect(abs(frames[0].minY - (frames[1].maxY + CmuxToastOverlayHost.stackGap)) < 0.5)

        composer.isHidden = true
        host.reanchor(in: window)
        #expect(abs(host.toastFrames(in: window)[1].minY - (CmuxToastOverlayHost.overlayLift)) < 0.5, "a hidden composer still held the toasts up")
        handles.forEach { $0.dismiss() }
    }

    /// The host listens to a window's avoided views only while it shows toasts there.
    @Test func theHostHearsAvoidanceChangesOnlyWhileItShowsToasts() async throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        try #require(window.contentView).addSubview(composer)
        let before = CmuxToastAvoidance.avoidanceChanged(in: window) != nil
        #expect(!before, "a window with no toast did work")

        let handle = center.show(CmuxToast(id: "a", message: "Saved", duration: CmuxToast.untilClosed), in: window)
        composer.frame.size.height = 160
        let move = try #require(CmuxToastAvoidance.avoidanceChanged(in: window), "the window's toast host was not reached")
        await move.value
        #expect(abs((host.toastFrames(in: window).first?.minY ?? 0) - (160 + CmuxToastAvoidance.avoidanceGap)) < 0.5)

        handle.dismiss()
        let after = CmuxToastAvoidance.avoidanceChanged(in: window) != nil
        #expect(!after, "a window with no toast left still starts a task per change")
    }

    /// The views that reserve room hear where the toasts rest when one shows, and again after a
    /// window resize, with the toast at the bottom center of the new size.
    @Test func reservingViewsHearWhereTheToastsRest() throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { Self.close(window) }
        let chat = ReservingSpy(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        try #require(window.contentView).addSubview(chat)
        let handle = center.show(CmuxToast(id: "saved", message: "Saved", duration: CmuxToast.untilClosed), in: window)
        let shown = try #require(chat.reports.last ?? nil, "no room reserved for the shown toast")
        #expect(shown == host.toastsRect(in: window))
        #expect(abs(shown.midX - 300) < 1)

        // A view that comes into the window later is told at once.
        let late = ReservingSpy(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        try #require(window.contentView).addSubview(late)
        CmuxToastAvoidance.reservingViewMoved(late, to: window)
        #expect(late.reports.last == shown)
        handle.dismiss()
    }
}

@MainActor
private final class AvoidedView: NSView, CmuxToastAvoiding {
    var toastAvoidanceRect: NSRect { bounds }
}

/// Records every toast rect it is told (nil: none shows).
@MainActor
private final class ReservingSpy: NSView, CmuxToastReserving {
    private(set) var reports: [NSRect?] = []
    func toastsSettled(in rect: NSRect?, duration: TimeInterval) { reports.append(rect) }
}
