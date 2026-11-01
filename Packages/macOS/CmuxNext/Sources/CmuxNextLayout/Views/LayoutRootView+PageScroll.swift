import AppKit
import CmuxNextDesign

/// A Command scroll over a web page goes to the page first (`layout.pagesHandleCommandScroll`,
/// Lawrence 2026-10-28: Figma and Excalidraw zoom with Command + scroll).
///
/// Under `layout.scrollModifier` `command`, a Command gesture or wheel notch that starts in a
/// Chromium page's own window, where the layout has something to scroll, is held, and the page is
/// asked once (``PageCommandScrollArbiter``) whether it cancels Command + wheel at the pointer.
/// Every event of the gesture that comes meanwhile is held too, momentum included.
///
/// - The page cancels it: the held events go to the page's window in order, the rest of the
///   gesture passes to it, and the layout does not move.
/// - It does not, or it does not answer within ``LayoutRootView/pageProbeDeadline``: the layout routes the held
///   events as if they had just come (the strip follows them), then the rest as usual.
///
/// The notches of one wheel spin reuse the first notch's answer for a short while, so a spin asks
/// once. With no arbiter (tests, an app without Chromium) or the setting off, nothing is held.
extension LayoutRootView {
    /// A Command scroll from a page window, held until its page answers.
    struct PageProbe {
        struct Held {
            var event: NSEvent
            var locationInWindow: NSPoint
        }

        /// The page's own window, where the held events go when the page keeps them.
        let window: NSWindow
        var held: [Held]
        let generation: UInt64
        /// A wheel notch, not a trackpad gesture.
        let isWheel: Bool
    }

    /// A page window's last wheel answer and until when it holds (event time).
    struct WheelPageAnswer {
        let window: ObjectIdentifier
        let pageKeeps: Bool
        var until: TimeInterval
    }

    /// How long one wheel answer holds after a notch: the gap between notches of one spin.
    private static let wheelSpinGap: TimeInterval = 0.3

    /// Holds `event` for its page when it must be. True: held (consumed for now); false: the page's
    /// earlier wheel answer gives it to the page; nil: route it as usual.
    func holdForPage(_ event: NSEvent, at locationInWindow: NSPoint, pageWindow: NSWindow?) -> Bool? {
        let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        if var probe = pageProbe {
            // Only the asked page's own scroll of the same kind waits for its answer: a scroll over
            // another pane or window, or a trackpad gesture during a wheel ask, is routed now.
            guard let pageWindow, pageWindow === probe.window, isWheel == probe.isWheel else { return nil }
            probe.held.append(PageProbe.Held(event: event, locationInWindow: locationInWindow))
            pageProbe = probe
            return true
        }
        guard let pageWindow, let arbiter = pageCommandScroll, model.scrollModifier == .command,
              model.pagesHandleCommandScroll, event.modifierFlags.contains(.command) else { return nil }
        if isWheel {
            if var answer = wheelPageAnswer, answer.window == ObjectIdentifier(pageWindow),
               event.timestamp <= answer.until {
                answer.until = event.timestamp + Self.wheelSpinGap
                wheelPageAnswer = answer
                return answer.pageKeeps ? false : nil
            }
        } else if !wouldDecideGestureOwner(event) {
            return nil
        }
        // Only where the layout would take it: elsewhere the page has it anyway.
        guard scrollTargets(event, at: locationInWindow, fromPageWindow: true).claimsWholeGesture else { return nil }
        pageProbeGeneration &+= 1
        let generation = pageProbeGeneration
        pageProbe = PageProbe(window: pageWindow, held: [PageProbe.Held(event: event, locationInWindow: locationInWindow)],
                              generation: generation, isWheel: isWheel)
        let point = event.locationInWindow
        pageProbeTask = Task { [weak self, weak pageWindow] in
            guard let pageWindow else { return }
            let keeps = await arbiter.pageHandlesCommandScroll(in: pageWindow, at: point)
            self?.resolvePageProbe(generation, pageKeeps: keeps)
        }
        // A stuck page never keeps the columns waiting; the answer cancels it.
        pageProbeTimer.schedule(after: pageProbeDeadline) { @MainActor [weak self] in
            self?.resolvePageProbe(generation, pageKeeps: false, timedOut: true)
        }
        return true
    }

    /// Whether `event` would decide its gesture's owner (``decidesGestureOwner(_:at:)`` without its
    /// bookkeeping): a touch, or a `began` no touch came before.
    private func wouldDecideGestureOwner(_ event: NSEvent) -> Bool {
        let phase = event.phase
        guard event.momentumPhase.isEmpty, !phase.isEmpty else { return false }
        if phase.contains(.mayBegin) { return true }
        return phase.contains(.began) && !ownerDecidedAtTouch
    }

    /// Applies the page's answer to the held scroll of `generation`; a late or repeated answer does nothing.
    /// `timedOut`: the deadline decided, not the page; that is not kept as the wheel spin's answer, so
    /// the next notch asks a slow page again.
    func resolvePageProbe(_ generation: UInt64, pageKeeps: Bool, timedOut: Bool = false) {
        guard let probe = pageProbe, probe.generation == generation else { return }
        pageProbe = nil
        pageProbeTimer.cancel()
        if probe.isWheel, !timedOut, let last = probe.held.last {
            wheelPageAnswer = WheelPageAnswer(window: ObjectIdentifier(probe.window), pageKeeps: pageKeeps,
                                              until: last.event.timestamp + Self.wheelSpinGap)
        }
        if pageKeeps {
            // The gesture is the page's: the touch and start it never routed decide nothing more here.
            for held in probe.held where !probe.isWheel { _ = decidesGestureOwner(held.event, at: held.locationInWindow) }
            if !probe.isWheel {
                scrollLock = .passthrough
                consumeMomentum = false
            }
            for held in probe.held { probe.window.sendEvent(held.event) }
            return
        }
        for held in probe.held {
            let routed = handleScrollEvent(held.event, at: held.locationInWindow, fromPageWindow: true,
                                           pageWindow: probe.window, replaying: true)
            // One the layout passes on after all (a gesture end it has no lock for) still reaches the page.
            if let routed { probe.window.sendEvent(routed) }
        }
    }
}
