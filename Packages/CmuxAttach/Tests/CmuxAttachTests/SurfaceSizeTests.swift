import Foundation
import Testing
@testable import CmuxAttach

@Suite struct SurfaceSizeTests {
    @Test func smallerClientWins() {
        let result = SurfaceSize.arbitrate(
            gui: SurfaceSize(cols: 120, rows: 40),
            attachments: [SurfaceSize(cols: 80, rows: 24)]
        )
        #expect(result == SurfaceSize(cols: 80, rows: 24))
    }

    @Test func mixedLargerAndSmallerDimensions() {
        // Client wider-than? no: client cols 100 < gui 120, client rows 50 > gui 40.
        // Each dimension is minimized independently.
        let result = SurfaceSize.arbitrate(
            gui: SurfaceSize(cols: 120, rows: 40),
            attachments: [SurfaceSize(cols: 100, rows: 50)]
        )
        #expect(result == SurfaceSize(cols: 100, rows: 40))
    }

    @Test func noAttachmentsReturnsGui() {
        let gui = SurfaceSize(cols: 132, rows: 43)
        #expect(SurfaceSize.arbitrate(gui: gui, attachments: []) == gui)
    }

    @Test func twoAttachmentsTakeMinOfBoth() {
        let result = SurfaceSize.arbitrate(
            gui: SurfaceSize(cols: 120, rows: 40),
            attachments: [SurfaceSize(cols: 80, rows: 24), SurfaceSize(cols: 100, rows: 30)]
        )
        #expect(result == SurfaceSize(cols: 80, rows: 24))
    }

    @Test func removingSmallestRestoresNextSmallest() {
        // Simulates a detach: the 80-wide attachment is gone, 100x30 remains.
        let result = SurfaceSize.arbitrate(
            gui: SurfaceSize(cols: 120, rows: 40),
            attachments: [SurfaceSize(cols: 100, rows: 30)]
        )
        #expect(result == SurfaceSize(cols: 100, rows: 30))
    }

    @Test func nonPositiveDimensionsAreIgnored() {
        let result = SurfaceSize.arbitrate(
            gui: SurfaceSize(cols: 120, rows: 40),
            attachments: [SurfaceSize(cols: 0, rows: 0), SurfaceSize(cols: 90, rows: -1)]
        )
        // cols: min(120, 90) = 90 (the 0 ignored); rows: only gui counts -> 40.
        #expect(result == SurfaceSize(cols: 90, rows: 40))
    }

    @Test func isPositiveReflectsBothDimensions() {
        #expect(SurfaceSize(cols: 80, rows: 24).isPositive)
        #expect(!SurfaceSize(cols: 0, rows: 24).isPositive)
        #expect(!SurfaceSize(cols: 80, rows: 0).isPositive)
    }

    @Test func codableRoundTrip() throws {
        let size = SurfaceSize(cols: 80, rows: 24)
        let data = try JSONEncoder().encode(size)
        let decoded = try JSONDecoder().decode(SurfaceSize.self, from: data)
        #expect(decoded == size)
    }
}
