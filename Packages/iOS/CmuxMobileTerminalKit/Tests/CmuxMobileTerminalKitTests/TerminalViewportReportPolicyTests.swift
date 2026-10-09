import Testing
import CMUXMobileCore
import CmuxMobileTerminalKit

@Suite("Terminal viewport report policy")
struct TerminalViewportReportPolicyTests {
    @Test("a pending reassert does not mint another report")
    func coalescesSameCapacityReassert() {
        #expect(!TerminalViewportReportPolicy(
            naturalGrid: grid(columns: 72, rows: 60),
            previousNaturalGrid: grid(columns: 72, rows: 60),
            shouldReassertNaturalSize: true,
            effectiveGrid: (columns: 72, rows: 60),
            viewportReportPending: true
        ).shouldReport)
    }

    @Test("a real capacity change supersedes a pending report")
    func preservesNaturalGridChanges() {
        #expect(TerminalViewportReportPolicy(
            naturalGrid: grid(columns: 73, rows: 60),
            previousNaturalGrid: grid(columns: 72, rows: 60),
            shouldReassertNaturalSize: true,
            effectiveGrid: (columns: 80, rows: 60),
            viewportReportPending: true
        ).shouldReport)
    }

    @Test("a settled mismatch can still reassert")
    func allowsSettledReassert() {
        #expect(TerminalViewportReportPolicy(
            naturalGrid: grid(columns: 72, rows: 60),
            previousNaturalGrid: grid(columns: 72, rows: 60),
            shouldReassertNaturalSize: true,
            effectiveGrid: (columns: 80, rows: 60),
            viewportReportPending: false
        ).shouldReport)
    }

    @Test("a smaller shared grid does not reassert the phone capacity")
    func acceptsMacConstrainedGrid() {
        #expect(!TerminalViewportReportPolicy(
            naturalGrid: grid(columns: 66, rows: 53),
            previousNaturalGrid: grid(columns: 66, rows: 53),
            shouldReassertNaturalSize: true,
            effectiveGrid: (columns: 66, rows: 35),
            viewportReportPending: false
        ).shouldReport)
    }

    @Test("pixel-only drift does not mint another report")
    func ignoresPixelOnlyDrift() {
        #expect(!TerminalViewportReportPolicy(
            naturalGrid: grid(columns: 72, rows: 60, pixelWidth: 1081, pixelHeight: 1777),
            previousNaturalGrid: grid(columns: 72, rows: 60, pixelWidth: 1080, pixelHeight: 1776),
            shouldReassertNaturalSize: false,
            effectiveGrid: (columns: 72, rows: 60),
            viewportReportPending: false
        ).shouldReport)
    }

    private func grid(
        columns: Int,
        rows: Int,
        pixelWidth: Int = 1080,
        pixelHeight: Int = 1776
    ) -> TerminalGridSize {
        TerminalGridSize(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}
