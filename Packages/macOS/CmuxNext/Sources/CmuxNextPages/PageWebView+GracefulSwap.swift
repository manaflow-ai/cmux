public import AppKit
import Foundation

// GRACEFUL-SWAP (Leo, 2026-11-22, after a layer swap reloaded his chat: "we need to have far more graceful
// reloads that appear to just be instantly gracefully transitioned ... no shift, no anything, just... ok now
// it changed"). A web bundle swap (a customize layer, a web-dev overlay, a web update) reloads each open page
// into the new web through here instead of a plain reload: the page hands its state over
// (`window.cmuxWebSwap.prepare()`, webviews/src/pages/shared/swapHandoff.ts), a shown page keeps its last
// frame as a still under its document, and the new document stays invisible over that still until it is
// the page it was (its draft, caret, chips, scroll and folds back) and then shows itself in one frame;
// the still goes once that frame is on screen. The page decides when it is back; the host only holds the
// picture and never waits past ``swapCoverLimit``.
extension PageWebView {
    /// The longest a swap's still stays over a page that never says it is back (the page's own cap is 1.5 s).
    static let swapCoverLimit: Duration = .milliseconds(2500)

    /// Reloads the page into the web now active, keeping what it shows (see above). A page that never
    /// loaded, or one whose process ended, reloads as before.
    public func swapReload() async {
        guard !isClosed else { return }
        guard loaded, !isParkedSpare else { return reloadPage() }
        let prepared = await callPageFunction(Self.swapPrepareScript, timeout: .milliseconds(400)) as? Bool == true
        guard !isClosed else { return }
        // A page without the hand-off (an older bundle, a page outside the desktop layer) reloads as before.
        guard prepared, isShownForHealth, let still = await swapStill(), !isClosed else { return reloadPage() }
        let cover = StillCover(frame: swapStillFrame)
        cover.image = still
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        // WebKit: over the view, since it paints its own background between the old document and the
        // new one's first script (a blank frame on Settings in the after-run). Chromium draws in a window
        // of its own over this view, so its still goes under the WebKit view, where that window shows it.
        addSubview(cover, positioned: showsChromium ? .below : .above, relativeTo: webKitView)
        reloadPage()
        let probe = await waitForSwapRestored()
        // Once the restored frame is on screen (Chromium draws in its own window a frame later).
        afterNextFrame { [weak cover] in cover?.removeFromSuperview() }
        if let probe { logger.info("web swap restored \(self.pageID, privacy: .public): \(probe, privacy: .public)") }
    }

    /// The page as it draws now, its clear areas kept clear (the window tint shows through them as before).
    private func swapStill() async -> NSImage? {
        showsChromium ? await clearAreaSnapshot() : await snapshot()
    }

    /// Where the still lies: a Chromium page's web contents start one band under the view's top (``chromiumFrameBand``).
    private var swapStillFrame: NSRect {
        guard showsChromium else { return bounds }
        let band = Self.chromiumFrameBand
        return NSRect(x: 0, y: isFlipped ? band : 0, width: bounds.width, height: max(0, bounds.height - band))
    }

    /// Waits for the new document to say it is back (`restored()`), at most ``swapCoverLimit``; its probe as JSON.
    private func waitForSwapRestored() async -> String? {
        let deadline = ContinuousClock.now + Self.swapCoverLimit
        while ContinuousClock.now < deadline, !isClosed {
            let left = deadline - ContinuousClock.now
            let answer = await callPageFunction(Self.swapRestoredScript, timeout: min(left, .milliseconds(1800)))
            if let text = answer as? String, text != "old", text != "boot" { return text }
            // The old document still answers, or the new one has no page script yet: look again soon.
            // wakeup-allow: a bounded poll across one reload, never past swapCoverLimit.
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    /// Marks the document it runs in as the old one and hands its state over; true when it did.
    static let swapPrepareScript = """
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.prepare !== 'function') return false;
        const kept = swap.prepare();
        if (kept) window.__cmuxSwapOld = true;
        return kept;
        """

    /// "old" before the reload replaced the document, "boot" before the new one's page script ran, else
    /// the probe (JSON, "null" when the new document had no hand-off).
    static let swapRestoredScript = """
        if (window.__cmuxSwapOld) return 'old';
        const swap = window.cmuxWebSwap;
        if (!swap || typeof swap.restored !== 'function') return 'boot';
        return JSON.stringify(await swap.restored());
        """
}
