import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// Austin 2026-11-10: "We need to make sure that the traffic lights are aligned to the densities as well".
/// The lights' placement on a top row line, with the numbers a live window gives: macOS's 32 pt container and
/// 14 pt buttons centered 16 pt down. The close button's left inset is its top inset (Lawrence 2026-11-10: "make sure
/// top land left are even"): 9 pt at macOS's place, as macOS draws it.
@Suite struct TrafficLightsLineTests {
    @Test func noLineIsMacOSPlace() {
        let placement = TrafficLightsLine.placement(centerY: nil, buttonHeight: 14, nativeHeight: 32, scale: 2)
        #expect(placement == .init(containerHeight: 32, centerY: 16, leadingX: 9))
    }

    /// Compact's and Default's lines (20 and 21.5 pt) fit macOS's container; the buttons only move.
    @Test func aLineInsideTheContainerMovesOnlyTheButtons() {
        for line in [20, 21.5] as [CGFloat] {
            let placement = TrafficLightsLine.placement(centerY: line, buttonHeight: 14, nativeHeight: 32, scale: 2)
            #expect(placement == .init(containerHeight: 32, centerY: line, leadingX: line - 7))
        }
    }

    /// Spacious's line (26.5 pt) puts the buttons' bottom at 33.5 pt: the container grows to hold them, on the pixel grid.
    @Test func aLineBelowTheContainerGrowsIt() {
        #expect(TrafficLightsLine.placement(centerY: 26.5, buttonHeight: 14, nativeHeight: 32, scale: 2)
            == .init(containerHeight: 33.5, centerY: 26.5, leadingX: 19.5))
        #expect(TrafficLightsLine.placement(centerY: 26.5, buttonHeight: 14, nativeHeight: 32, scale: 1)
            == .init(containerHeight: 34, centerY: 27, leadingX: 20))
    }

    @Test func theCenterSitsOnTheDevicePixelGrid() {
        #expect(TrafficLightsLine.placement(centerY: 20.3, buttonHeight: 14, nativeHeight: 32, scale: 2).centerY == 20.5)
        #expect(TrafficLightsLine.placement(centerY: 20.3, buttonHeight: 14, nativeHeight: 32, scale: 1).centerY == 20)
    }
}
