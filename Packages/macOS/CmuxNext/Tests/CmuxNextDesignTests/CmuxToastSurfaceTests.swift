import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The one toast component: the shared neutral glass (opaque under Reduce Transparency) with a small radius,
/// bottom-center of its window above the content edge, held while the pointer is on it.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastSurfaceTests {
    private static func surface(of view: CmuxToastView) throws -> OverlaySurfaceView {
        try #require(view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
    }

    /// Under Reduce Transparency the toast is an opaque fill in the theme's colors (otherwise it is
    /// the shared neutral glass, FloatingGlassStyleTests).
    @Test func reduceTransparencyMakesTheToastAnOpaqueThemeSurface() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo()),
                                 reduceTransparency: ReduceTransparency(system: { true }, changes: NotificationCenter()))
        let surface = try Self.surface(of: view)
        #expect(surface.material == .opaque)
        let fill = try #require(surface.subviews.first?.layer?.backgroundColor)
        #expect(fill.alpha == 1)
    }

    /// A rounded rect with the shared glass radius (continuous corners), never a capsule.
    @Test func theToastHasASmallCornerRadius() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Saved"))
        view.layoutSubtreeIfNeeded()
        let surface = try Self.surface(of: view)
        #expect(surface.cornerRadius == FloatingGlassStyle.toast.cornerRadius)
        #expect(surface.cornerRadius < view.fittingSize.height / 2)
    }

    /// Where the overlay host draws a toast of `size` in `slot`: the host's anchor, placed by the
    /// window overlay as a `.toast`.
    private static func frame(slot: Int, size: NSSize, in bounds: NSRect) -> NSRect {
        let anchor = CmuxToastOverlayHost.anchor(slot: slot, height: size.height, in: bounds)
        let origin = WindowOverlayHost.origin(for: size, options: OverlayOptions(kind: .toast, anchor: anchor), in: bounds)
        return NSRect(origin: origin, size: size)
    }

    /// Bottom-center of the window, its bottom edge a margin above the content's bottom edge;
    /// a second toast stacks above the first.
    @Test func theToastSitsBottomCenterAboveTheContentEdge() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: 260, height: 36)
        let first = Self.frame(slot: 0, size: size, in: bounds)
        #expect(abs(first.midX - bounds.midX) < 0.5)
        #expect(first.minY >= bounds.minY + 16)
        #expect(first.minY <= bounds.minY + 32)
        let second = Self.frame(slot: 1, size: size, in: bounds)
        #expect(second.minY >= first.maxY + 4)
        #expect(abs(second.midX - bounds.midX) < 0.5)
    }

    /// The pointer on a toast holds it past its time; leaving lets it end.
    @Test func hoverPausesTheDismissal() async throws {
        let center = CmuxToastCenter(host: HeadlessToastHost())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeWithOverlayHost() }
        let handle = center.show(CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo(),
                                           duration: .milliseconds(150)), in: window)
        center.setHovered(true, handle)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!handle.isDismissed)
        #expect(center.toasts(in: window).count == 1)
        center.setHovered(false, handle)
        for _ in 0..<40 where !handle.isDismissed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(handle.isDismissed)
        #expect(center.toasts(in: window).isEmpty)
    }

    /// A repeated toast (the same refusal again) takes the shown one's place in one frame: it
    /// neither blinks out and fades back in from nothing nor rises again (motion pass, 2026-10-12).
    @Test func aSameIdToastReplacesTheShownOneInPlace() throws {
        let center = CmuxToastCenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let first = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        let shown = try #require(Self.toastViews(in: window).first)
        #expect(shown.layer?.animation(forKey: "opacity") != nil, "a new toast fades in")

        let second = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        #expect(first.isDismissed)
        let views = Self.toastViews(in: window)
        #expect(views.count == 1)
        let replacement = try #require(views.first)
        #expect(replacement !== shown)
        #expect(replacement.layer?.animation(forKey: "opacity") == nil, "the replacement faded in from nothing")
        #expect(replacement.layer?.animation(forKey: "transform.translation.y") == nil, "the replacement rose again")
        second.dismiss()
    }

    /// Toasts stay clear of the Home composer; when it grows, a shown toast slides up with it
    /// instead of jumping there in one frame (motion pass, 2026-10-12).
    @Test func aToastSlidesClearOfAGrowingAvoidedView() throws {
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        try #require(window.contentView).addSubview(composer)
        let handle = center.show(CmuxToast(id: "saved", message: "Saved"), in: window)
        let toast = try #require(Self.toastViews(in: window).first)
        toast.layer?.removeAllAnimations() // its arrival is done
        let before = toast.convert(toast.bounds, to: nil).minY

        composer.frame.size.height = 160
        // What `CmuxToastAvoidance.avoidanceChanged(in:)` runs a turn later, here in the same turn:
        // in this offscreen window the slide is gone by the next run loop pass.
        host.reanchor(in: window)
        #expect(toast.convert(toast.bounds, to: nil).minY >= before + 99, "the toast moved clear of the composer")
        #expect(toast.layer?.animation(forKey: "transform.translation.y") != nil, "the toast jumped there in one frame")
        handle.dismiss()
    }

    /// An avoided view that changes in one window moves only that window's toasts: the one host
    /// that shows toasts in every window re-reads the avoided views of that window alone, and a
    /// window that never showed a toast does no work (the app-wide notice woke every host for
    /// every window).
    @Test func anAvoidanceChangeInOneWindowMovesOnlyThatWindowsToasts() async throws {
        let host = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: host)
        func window() throws -> (NSWindow, AvoidedView) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
            try #require(window.contentView).addSubview(composer)
            return (window, composer)
        }
        let (windowA, composerA) = try window()
        let (windowB, composerB) = try window()
        let (quiet, _) = try window()
        defer { [windowA, windowB, quiet].forEach { $0.closeWithOverlayHost() } }
        let handles = [center.show(CmuxToast(id: "a", message: "Saved"), in: windowA),
                       center.show(CmuxToast(id: "b", message: "Saved"), in: windowB)]
        let toastA = try #require(Self.toastViews(in: windowA).first)
        let toastB = try #require(Self.toastViews(in: windowB).first)
        let beforeA = toastA.convert(toastA.bounds, to: nil).minY
        let beforeB = toastB.convert(toastB.bounds, to: nil).minY

        // Both composers grow; only window A says so.
        composerA.frame.size.height = 160
        composerB.frame.size.height = 160
        let move = try #require(CmuxToastAvoidance.avoidanceChanged(in: windowA), "window A's host was not reached")
        await move.value
        #expect(toastA.convert(toastA.bounds, to: nil).minY >= beforeA + 99, "window A's toast stayed under its composer")
        #expect(toastB.convert(toastB.bounds, to: nil).minY == beforeB, "window B's toast moved for window A's change")
        let quietWorked = CmuxToastAvoidance.avoidanceChanged(in: quiet) != nil
        #expect(!quietWorked, "a window with no toast host did work")

        // Window B's own change moves window B's toast.
        await CmuxToastAvoidance.avoidanceChanged(in: windowB)?.value
        #expect(toastB.convert(toastB.bounds, to: nil).minY >= beforeB + 99)
        handles.forEach { $0.dismiss() }
    }

    /// Each window's change reaches the host that shows toasts there, not another window's host:
    /// a spy registered as window B's host records what window A's change asks of it (a real host
    /// would skip window A's entries, so its toasts could not show the call).
    @Test func anAvoidanceChangeReachesOnlyTheHostOfItsWindow() async throws {
        let hostA = CmuxToastOverlayHost()
        let center = CmuxToastCenter(host: hostA)
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                     backing: .buffered, defer: false)
        }
        defer { windows.forEach { $0.closeWithOverlayHost() } }
        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        try #require(windows[0].contentView).addSubview(composer)
        let handle = center.show(CmuxToast(id: "t", message: "Saved"), in: windows[0])
        let spyB = ReanchorSpy()
        CmuxToastAvoidance.register(spyB, in: windows[1])
        let toast = try #require(Self.toastViews(in: windows[0]).first)
        let before = toast.convert(toast.bounds, to: nil).minY

        composer.frame.size.height = 160
        await CmuxToastAvoidance.avoidanceChanged(in: windows[0])?.value
        #expect(toast.convert(toast.bounds, to: nil).minY >= before + 99, "host A did not move its toast")
        #expect(spyB.reanchored.isEmpty, "window B's host was reached for window A's change")

        await CmuxToastAvoidance.avoidanceChanged(in: windows[1])?.value
        #expect(spyB.reanchored.map { $0 === windows[1] } == [true], "window B's host missed its own window's change")
        CmuxToastAvoidance.unregister(spyB, from: windows[1])
        handle.dismiss()
    }

    /// A host whose last toast in a window goes stops listening there: the window's next change
    /// starts no task (the host stays alive, as CmuxToastCenter.shared's does for the whole app).
    @Test func aWindowWhoseToastsAllWentDoesNoWorkOnAnAvoidanceChange() async throws {
        let center = CmuxToastCenter(host: CmuxToastOverlayHost())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let first = center.show(CmuxToast(id: "t1", message: "Saved"), in: window)
        let second = center.show(CmuxToast(id: "t2", message: "Saved"), in: window)

        first.dismiss()
        let stillShowing = try #require(CmuxToastAvoidance.avoidanceChanged(in: window),
                                        "the window's remaining toast no longer moves")
        await stillShowing.value
        second.dismiss()
        let afterLastWorked = CmuxToastAvoidance.avoidanceChanged(in: window) != nil
        #expect(!afterLastWorked, "a window with no toast left still starts a task per change")
    }

    /// Two hosts that show toasts in the same window both move them: a later host does not take
    /// the window from an earlier one (the app-wide notice reached every host).
    @Test func anAvoidanceChangeMovesTheToastsOfEveryHostInItsWindow() async throws {
        let hosts = [CmuxToastOverlayHost(), CmuxToastOverlayHost()]
        let centers = hosts.map { CmuxToastCenter(host: $0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        try #require(window.contentView).addSubview(composer)
        let handles = centers.enumerated().map { $1.show(CmuxToast(id: "t\($0)", message: "Saved"), in: window) }
        let toasts = try ["t0", "t1"].map { id in try #require(Self.toastViews(in: window).first { $0.toast.id == id }) }
        let before = toasts.map { $0.convert($0.bounds, to: nil).minY }

        composer.frame.size.height = 160
        let move = try #require(CmuxToastAvoidance.avoidanceChanged(in: window), "no host was reached")
        await move.value
        #expect(toasts[0].convert(toasts[0].bounds, to: nil).minY >= before[0] + 99, "the first host's toast stayed under the composer")
        #expect(toasts[1].convert(toasts[1].bounds, to: nil).minY >= before[1] + 99, "the second host's toast stayed under the composer")
        handles.forEach { $0.dismiss() }
    }

    /// A fourth toast pushes the oldest out: it fades above the stack, clear of the toast that
    /// moves up into its old slot, instead of the two overlapping while it fades (motion pass).
    @Test func aToastPushedOutFadesClearOfTheOneTakingItsSlot() throws {
        let center = CmuxToastCenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let handles = (1...3).map { center.show(CmuxToast(id: "t\($0)", message: "Toast \($0)"), in: window) }
        let oldest = try #require(Self.toastViews(in: window).first { $0.toast.id == "t1" })
        let fourth = center.show(CmuxToast(id: "t4", message: "Toast 4"), in: window)
        #expect(handles[0].isDismissed)
        let leaving = oldest.convert(oldest.bounds, to: nil)
        for view in Self.toastViews(in: window) where view !== oldest {
            #expect(!view.convert(view.bounds, to: nil).intersects(leaving), "\(view.toast.id) overlaps the leaving toast")
        }
        (handles + [fourth]).forEach { $0.dismiss() }
    }

    /// A taller toast pushing out the oldest: the one leaving still fades clear of every toast that
    /// stays, measured on the stack's final heights (review of #27807).
    @Test func aToastPushedOutByATallerOneFadesClearOfIt() throws {
        let center = CmuxToastCenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let handles = (1...3).map { center.show(CmuxToast(id: "t\($0)", message: "Toast \($0)"), in: window) }
        let oldest = try #require(Self.toastViews(in: window).first { $0.toast.id == "t1" })
        let long = String(repeating: "A machine could not update to this Mac's build. ", count: 4)
        let fourth = center.show(CmuxToast(id: "t4", message: long), in: window)
        #expect(handles[0].isDismissed)
        let tall = try #require(Self.toastViews(in: window).first { $0.toast.id == "t4" })
        #expect(tall.frame.height > oldest.frame.height + 8, "the fourth toast is not taller")
        let leaving = oldest.convert(oldest.bounds, to: nil)
        for view in Self.toastViews(in: window) where view !== oldest {
            #expect(!view.convert(view.bounds, to: nil).intersects(leaving), "\(view.toast.id) overlaps the leaving toast")
        }
        (handles + [fourth]).forEach { $0.dismiss() }
    }

    /// The toasts shown over `window`: they live in its overlay panel, a child window.
    private static func toastViews(in window: NSWindow) -> [CmuxToastView] {
        func walk(_ view: NSView) -> [CmuxToastView] {
            (view as? CmuxToastView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return WindowOverlayHost.host(for: window).panel.contentView.map(walk) ?? []
    }
}

@MainActor
private final class AvoidedView: NSView, CmuxToastAvoiding {
    var toastAvoidanceRect: NSRect { bounds }
}

/// Records each window it is asked to reanchor in.
@MainActor
private final class ReanchorSpy: CmuxToastReanchoring {
    private(set) var reanchored: [NSWindow] = []
    func reanchor(in window: NSWindow) { reanchored.append(window) }
}

@MainActor
private final class HeadlessToastHost: CmuxToastHosting {
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
