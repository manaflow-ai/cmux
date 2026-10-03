import AppKit
import Testing
@testable import CmuxNextUpdater

/// The update circle and its note draw like the Codex app's: a round disc on
/// device pixels with a thin ring, and a note with square-ish corners.
@MainActor
@Suite struct UpdateIndicatorGeometryTests {
    @Test func theDiscIsSquareAndCenteredOnDevicePixels() {
        // An odd leftover: the point grid can't center it, the 2x pixel grid can.
        let bounds = CGRect(x: 0, y: 0, width: 45, height: 40)
        let rect = UpdateIndicatorView.discRect(in: bounds, scale: 2)
        #expect(rect.width == rect.height)
        #expect(rect.midX == bounds.midX)
        #expect(rect.midY == bounds.midY)
        for value in [rect.minX, rect.minY, rect.width] {
            #expect((value * 2).rounded() == value * 2)
        }
        let oneX = UpdateIndicatorView.discRect(in: bounds, scale: 1)
        #expect(oneX.minX.rounded() == oneX.minX)
    }

    @Test func layersRasterizeAtTheBackingScale() {
        let view = UpdateIndicatorView(frame: CGRect(x: 0, y: 0, width: 44, height: 40))
        view.backingScale = 2
        view.show(.installing, toolTip: nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.layerContentsScales == [2, 2, 2])
        view.backingScale = 3
        #expect(view.layerContentsScales == [3, 3, 3])
    }

    @Test func theBusyRingIsAThinArcInsideTheDisc() {
        let view = UpdateIndicatorView(frame: CGRect(x: 0, y: 0, width: 44, height: 40))
        view.backingScale = 2
        view.show(.installing, toolTip: nil)
        view.layoutSubtreeIfNeeded()
        let disc = view.discFrame
        let ring = view.ringFrame
        #expect(view.ringLineWidth <= 1.25)
        #expect(ring.width == ring.height)
        #expect(ring.width < disc.width / 2)
        #expect(ring.midX == disc.midX && ring.midY == disc.midY)
    }

    @Test func theNoteIsARoundedRectangleNotACapsule() {
        let pill = UpdatePillView(frame: CGRect(x: 0, y: 0, width: 160, height: 24))
        pill.text = "cmux Is Up to Date"
        pill.layoutSubtreeIfNeeded()
        #expect(pill.cornerRadius > 0)
        #expect(pill.cornerRadius <= 24 / 4)
    }
}
