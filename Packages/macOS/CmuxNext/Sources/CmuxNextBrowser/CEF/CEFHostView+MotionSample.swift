#if DEBUG || CMUX_BENCH_HOOKS
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
    /// `page`: `[host width, host height, page window width, page window height, wall ms, hidden]`.
    /// The page window is the child window the fork keeps over this view (the content child
    /// window nearest the host's screen rect; -1 when none is near). `wall ms` is the epoch
    /// time of the sample, so a bench can line it up with the page's own clock
    /// (`performance.timeOrigin + requestAnimationFrame`'s timestamp) and count the frames
    /// between the host taking a size and the page laying out at it
    /// (scripts/ci/frame-pacing/golden.py `browser_resize`). `hidden` is 1 while a spring hides a page in its
    /// own window (`ChildWindowPageFallback.hidesForSpring`): its window frame is not what shows then, so a
    /// bench comparing page window and host frames skips those samples, else 0. Then the host in the window
    /// `[x, y]` (points, top-left origin), the area of its page cutouts (`ChildWindowPageFallback.cutouts(around:)`:
    /// what the panes in front cover, which a page in its own window leaves out), and 1 when the page draws in its
    /// own window (`drawsInChildWindow`), else 0: a zoom bench checks no page window draws over the zooming pane.
    static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let host = view as? CEFHostView else { return nil }
        guard let window = host.window, !host.isHiddenOrHasHiddenAncestor, !host.bounds.isEmpty else { return [:] }
        let screenRect = window.convertToScreen(host.convert(host.bounds, to: nil))
        let page = (window.childWindows ?? [])
            .filter { $0.isVisible && abs($0.frame.minX - screenRect.minX) < 2 && abs($0.frame.maxY - screenRect.maxY) < 2 }
            .min { abs($0.frame.width - screenRect.width) < abs($1.frame.width - screenRect.width) }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        // wall-clock: browser_resize.py matches it to the page's epoch `performance.timeOrigin + t`.
        let wallMs = (Date().timeIntervalSince1970 * 1_000_000).rounded() / 1_000
        let inWindow = host.convert(host.bounds, to: nil), height = window.frame.height  // as the layout sampler reads its panes
        let cut = ChildWindowPageFallback.cutouts(around: host).reduce(0.0) { area, rect in
            let shown = rect.intersection(host.bounds)
            return shown.isNull ? area : area + Double(shown.width * shown.height)
        }
        let row: [Any] = [rounded(host.bounds.width), rounded(host.bounds.height),
                          page.map { rounded($0.frame.width) } ?? -1, page.map { rounded($0.frame.height) } ?? -1, wallMs,
                          ChildWindowPageFallback.hidesForSpring(host) ? 1 : 0,
                          rounded(inWindow.minX), rounded(height - inWindow.maxY), (cut * 100).rounded() / 100,
                          host.drawsInChildWindow ? 1 : 0]
        return ["page": [row]]
    }
}
#endif
