#if DEBUG
import AppKit
import CmuxNextDesign

extension CEFHostView {
    private static var samplerRegistered = false

    /// Adds `motionSample` to `debug.motion`'s trace samplers, once (the first host view).
    static func registerMotionSampler() {
        guard !samplerRegistered else { return }
        samplerRegistered = true
        MotionDebug.registeredSamplers.append(motionSample)
    }

    /// `debug.motion` `trace_*` sampler: per display frame, each shown Chromium host as
    /// `page`: `[host width, host height, page window width, page window height, wall ms,
    /// host screen x, page window screen x, page area width]`.
    /// The page window is the child window the fork keeps over this view (the content child
    /// window whose top edge is the host's and whose left edge is nearest it; -1 when none is near).
    /// The page area is the host's superview (the tab's content view): the host may be held
    /// at another size than it through a pane resize drag (`CEFTabContentView`). `wall ms` is the epoch
    /// time of the sample, so a bench can line it up with the page's own clock
    /// (`performance.timeOrigin + requestAnimationFrame`'s timestamp) and count the frames
    /// between the host taking a size and the page laying out at it
    /// (scripts/ci/frame-pacing/golden.py `browser_resize`).
    static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let host = view as? CEFHostView else { return nil }
        guard let window = host.window, !host.isHiddenOrHasHiddenAncestor, !host.bounds.isEmpty else { return [:] }
        let screenRect = window.convertToScreen(host.convert(host.bounds, to: nil))
        // A page window that trails its host's left edge (a divider drag moves it) is still the
        // nearest one along the same top edge; a divider's catcher panel there is far narrower.
        let page = (window.childWindows ?? [])
            .filter { $0.isVisible && abs($0.frame.maxY - screenRect.maxY) < 2 && $0.frame.width > screenRect.width / 2
                && abs($0.frame.minX - screenRect.minX) < max(2, screenRect.width / 2) }
            .min { abs($0.frame.minX - screenRect.minX) < abs($1.frame.minX - screenRect.minX) }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        let row: [Any] = [rounded(host.bounds.width), rounded(host.bounds.height),
                          page.map { rounded($0.frame.width) } ?? -1, page.map { rounded($0.frame.height) } ?? -1,
                          (Date().timeIntervalSince1970 * 1_000_000).rounded() / 1_000,
                          rounded(screenRect.minX), page.map { rounded($0.frame.minX) } ?? -1,
                          rounded(host.superview?.bounds.width ?? host.bounds.width)]
        return ["page": [row]]
    }
}
#endif
