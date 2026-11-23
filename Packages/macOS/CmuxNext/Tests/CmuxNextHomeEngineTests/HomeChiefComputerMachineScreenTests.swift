import CoreGraphics
@testable import CmuxNextHomeEngine
import Testing

@Suite struct HomeChiefComputerMachineScreenTests {
    @Test func theInlineFrameAndThePointerAreReadFromOneExecOutput() {
        let output = "frame:/9j/4AAQ\n{\n  \"x\": 120,\n  \"y\": 48\n}\n"
        #expect(HomeChiefComputerRoute.machineFrame(output) == "/9j/4AAQ")
        #expect(HomeChiefComputerRoute.machinePointer(output) == CGPoint(x: 120, y: 48))
    }

    @Test func anEmptyFrameLineFallsBackToTheFileRead() {
        let output = "frame:\n{\"x\": 1, \"y\": 2}\n"
        #expect(HomeChiefComputerRoute.machineFrame(output) == nil)
        #expect(HomeChiefComputerRoute.machinePointer(output) == CGPoint(x: 1, y: 2))
    }

    @Test func aFrameWithoutAPointerSaysNoPointer() {
        #expect(HomeChiefComputerRoute.machinePointer("frame:{abc\n") == nil)
    }
}
