public import AppKit
public import CmuxNextDesign

/// A Chromium page that lies out of sight in its window: a New Tab spare in its off-screen parking, a kept
/// closed chat, the reserved Cmd-N workspace's page, a moved page held outside the window. Its child window
/// ignores the alpha that keeps it out of sight, so such a page used to stay visible to Chromium for as long
/// as it waited there: never frozen or released, its renderer and the GPU process kept working for a page
/// nobody sees (CMUX-571, cmux#43767: 150 s after the last chat opened, 3 of 4 live pages reported visible,
/// with the Chromium GPU process at 93 wakeups/s and 210 MB against 1.0/s and 49 MB empty).
///
/// Such a page draws only while something waits for it to, as a background tab in Chrome renders only for
/// a capture: until its document painted, until it drew a frame at the size it waits at (a spare paints
/// before it is adopted, so a Cmd-T shows a page already drawn), while a frame wait or a picture of it runs,
/// and while its owner holds it away until it shows (``PageWebView/drawsWhileAway``). Then it reports
/// hidden, like a chat behind another tab, and keeps the frame it drew.
@MainActor
final class PageAwayDrawing {
    /// Frame waits and pictures in flight (``PageWebView/afterNextFrame(_:)``, ``PageWebView/afterFrame(at:_:)``,
    /// ``PageWebView/snapshot()``): the page draws for them wherever it is.
    var holds = 0
    /// The size the page drew a frame at while out of sight; nil when it has not since its document painted.
    var drawnSize: CGSize?
    /// The size a frame wait of its own runs for now (``PageWebView/drawAwayIfNeeded()``).
    var drawing: CGSize?
}

/// The reserved Cmd-N workspace shows (`WorkspaceContentView.setParked(false)`): it moves into the window
/// and its alpha comes back, which no layout of the page follows, so the page shows to Chromium again here.
extension PageWebView: ParkingObserver {
    public func parkingDidChange() { setChromiumVisibility(true) }
}

extension PageWebView {
    /// Whether the page lies out of sight in its window: wholly outside the window's content, or in an
    /// off-screen parking (``PageOffscreenParking``).
    var inOffscreenParking: Bool {
        sequence(first: self as NSView, next: \.superview).dropFirst().contains { $0 is PageOffscreenParking }
    }

    /// Whether a page out of sight draws now: until it painted and drew at the size it waits at, while
    /// a frame wait or picture of it runs, and while its owner holds it away (``drawsWhileAway``).
    var drawsAway: Bool {
        !hasPainted || drawsWhileAway || awayDrawing.holds > 0 || awayDrawing.drawnSize != bounds.size
    }

    /// A painted page out of sight that has not drawn at its size there: one frame wait at that size, after
    /// which it reports hidden (the wait's hold ends with it).
    func drawAwayIfNeeded() {
        let size = bounds.size
        guard hasPainted, !drawsWhileAway, awayDrawing.holds == 0, awayDrawing.drawnSize != size,
              awayDrawing.drawing != size, size.width >= 1, size.height >= 1 else { return }
        awayDrawing.drawing = size
        afterFrame(at: size) { [weak self] in
            guard let self, awayDrawing.drawing == size else { return }
            awayDrawing.drawing = nil
            awayDrawing.drawnSize = size
        }
    }

    /// Something waits for the page to draw (a frame wait, a picture): a Chromium page out of sight shows
    /// to Chromium until ``releaseAwayDrawing()``. True when it took a hold (a Chromium page), which the
    /// caller then releases once.
    func holdAwayDrawing() -> Bool {
        guard chromiumSession != nil else { return false }
        awayDrawing.holds += 1
        if awayDrawing.holds == 1 { setChromiumVisibility(true) }
        return true
    }

    /// The wait ``holdAwayDrawing()`` took ended. Callers release after their waiter ran, so a picture that
    /// waiter starts at once (a spare's cover after its frame) holds the page drawing first.
    func releaseAwayDrawing() {
        guard awayDrawing.holds > 0 else { return }
        awayDrawing.holds -= 1
        if awayDrawing.holds == 0 { setChromiumVisibility(true) }
    }
}
