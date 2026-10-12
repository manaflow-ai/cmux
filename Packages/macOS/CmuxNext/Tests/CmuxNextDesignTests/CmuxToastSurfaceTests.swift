import AppKit
@testable import CmuxNextDesign
import Testing

/// The one toast component (op-next-theme toasts): a solid theme surface with a small radius,
/// bottom-center of its window above the content edge, held while the pointer is on it.
@MainActor
struct CmuxToastSurfaceTests {
    private static func surface(of view: CmuxToastView) throws -> OverlaySurfaceView {
        try #require(view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
    }

    /// Not translucent glass: an opaque fill in the theme's colors, whatever this Mac's material.
    @Test func theToastIsAnOpaqueThemeSurface() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo()))
        let surface = try Self.surface(of: view)
        #expect(surface.material == .opaque)
        let fill = try #require(surface.subviews.first?.layer?.backgroundColor)
        #expect(fill.alpha == 1)
        let theme = surface.themeTokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).cgColor
        let a = try #require(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
        let b = try #require(NSColor(cgColor: theme)?.usingColorSpace(.sRGB))
        #expect(abs(a.redComponent - b.redComponent) < 0.01)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.01)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.01)
    }

    /// A small rounded rect like the popups, never a capsule.
    @Test func theToastHasASmallCornerRadius() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Saved"))
        view.layoutSubtreeIfNeeded()
        let surface = try Self.surface(of: view)
        #expect(surface.cornerRadius <= PopupStyle.standard.cornerRadius)
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

    private static func toastViews(in window: NSWindow) -> [CmuxToastView] {
        func walk(_ view: NSView) -> [CmuxToastView] {
            (view as? CmuxToastView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return (window.contentView?.superview ?? window.contentView).map(walk) ?? []
    }
}

@MainActor
private final class HeadlessToastHost: CmuxToastHosting {
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
