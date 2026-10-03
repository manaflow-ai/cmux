import CoreGraphics
@testable import CmuxNextIcons
import Testing

struct IconPathTests {
    @Test func parsesAbsoluteMoveLineCurveAndClose() throws {
        let path = try #require(CGPath.icon("M20.5 12C20.5 16.694 16.694 20.5 12 20.5L3 3ZM1 1L2,2"))
        let box = path.boundingBoxOfPath
        #expect(box.minX == 1)
        #expect(box.minY == 1)
        #expect(box.maxX == 20.5)
        #expect(box.maxY == 20.5)
    }

    @Test func parsesNegativeNumbersWithoutSpaces() throws {
        let path = try #require(CGPath.icon("M-1-2L3 4"))
        #expect(path.boundingBoxOfPath.minX == -1)
        #expect(path.boundingBoxOfPath.minY == -2)
    }

    @Test func rejectsRelativeAndUnsupportedCommands() {
        #expect(CGPath.icon("m1 1") == nil)
        #expect(CGPath.icon("M1 1l2 2") == nil)
        #expect(CGPath.icon("M1 1A2 2 0 0 1 3 3") == nil)
        #expect(CGPath.icon("M1 1Q2 2 3 3") == nil)
    }

    @Test func rejectsMalformedData() {
        #expect(CGPath.icon("") == nil)
        #expect(CGPath.icon("L1 1") == nil)
        #expect(CGPath.icon("M1") == nil)
        #expect(CGPath.icon("M1 1L2") == nil)
        #expect(CGPath.icon("M1 1C1 2 3") == nil)
    }
}
