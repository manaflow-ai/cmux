#if os(iOS)
import CmuxMobileLinkFFI
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24: "where's us simply scrolling a cached-on-phone view of a
/// lot of the existing terminal data that's been sent and rendered? ... if it
/// won't change, there's no lag" and "we can just treat the scroll like any
/// pedestrian scroll". A full-screen app's rows it scrolled away are kept by
/// the phone's projection; the reader scrolls them as a plain scroll view,
/// through a real Ghostty surface, with nothing sent to the app.
@MainActor
@Suite(.serialized) struct TerminalTUIReaderTests {
    /// A full-screen app 40x10 that scrolled a 21-row transcript by 3 rows a
    /// frame (inside synchronized updates, as Claude Code draws).
    static func scrolledApp() -> TerminalProjection {
        let projection = TerminalProjection(hostCols: 40, hostRows: 10)
        _ = projection.setViewport(cols: 40, rows: 10)
        _ = projection.feed(bytes: Data("\u{1b}[?1049h".utf8), paint: true)
        for first in stride(from: 0, through: 12, by: 3) {
            var frame = "\u{1b}[?2026h\u{1b}[H\u{1b}[2J"
            for row in 0..<9 { frame += "\u{1b}[\(row + 1);1Hline \(String(format: "%03d", first + row))" }
            frame += "\u{1b}[10;1H> status\u{1b}[?2026l"
            _ = projection.feed(bytes: Data(frame.utf8), paint: true)
        }
        return projection
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theAppsScrolledAwayRowsScrollAsAPlainScrollView() async throws {
        let projection = Self.scrolledApp()
        #expect(projection.transcriptRowsAbove() == 12)
        let paint = try #require(projection.transcriptPaint())
        let transcript = TerminalTUITranscript(bytes: paint.bytes, rows: Int(paint.rows), screenTop: Int(paint.screenTop))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        // The app's own surface, for its cell size.
        let app = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.addSubview(app)
        let cell = app.cellSize
        try #require(cell.height > 0)
        let reader = TerminalTUIReader()
        let area = CGRect(x: 0, y: 0, width: 360, height: 10 * cell.height)
        reader.open(transcript, in: host, frame: area, surfaceX: 0, width: 360, cellHeight: cell.height, themeMacID: nil, background: nil)

        // It opens at the bottom: the app's screen, as the live surface shows it.
        #expect(await Self.waitUntil { reader.isShowing })
        #expect(reader.scrollView.contentSize.height == CGFloat(transcript.rows) * cell.height)
        let bottom = try #require(reader.visibleRowTexts())
        #expect(bottom.first?.hasPrefix("line 012") == true, "\(bottom)")
        #expect(bottom.last?.hasPrefix("> status") == true, "\(bottom)")

        // Scrolled to the top by points: the oldest row the app showed, from
        // the phone's own copy.
        reader.scrollView.setContentOffset(.zero, animated: false)
        #expect(await Self.waitUntil { reader.visibleRowTexts()?.first?.hasPrefix("line 000") == true })
        // Half a row down: the scroll is by points, not rows.
        reader.scrollView.setContentOffset(CGPoint(x: 0, y: cell.height / 2), animated: false)
        #expect(reader.scrollView.contentOffset.y == cell.height / 2)

        // A drag handed over from the app's pan moves it the finger's distance.
        reader.dragBegan()
        reader.dragMoved(translationY: -cell.height * 3)
        #expect(reader.scrollView.contentOffset.y == cell.height * 3.5)

        // Back at the bottom and settled: it closes, the app's screen shows.
        var closed = false
        reader.onClose = { closed = true }
        reader.scrollView.setContentOffset(CGPoint(x: 0, y: reader.scrollView.contentSize.height - area.height), animated: false)
        reader.scrollViewDidEndDecelerating(reader.scrollView)
        #expect(closed)
        #expect(!reader.isOpen)
    }

    @Test func aRubberBandPastTheTopShowsLessThanTheFingerMoved() {
        #expect(TerminalTUIReader.rubberBand(0, dimension: 600) == 0)
        let shown = TerminalTUIReader.rubberBand(200, dimension: 600)
        #expect(shown > 0 && shown < 200)
    }
}
#endif
