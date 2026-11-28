import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileTerminalInputFrameTests {
    @Test func fragmentedMarkedAndLegacyFramesPreserveOrder() throws {
        let frames = [MobileTerminalInputFrame(text: "é", sequence: UInt64.max - 2), MobileTerminalInputFrame(text: "old"), MobileTerminalInputFrame(text: "next", sequence: 42)]
        let wire = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        var buffer = Data()
        var result: [MobileTerminalInputFrame] = []
        for byte in wire { buffer.append(byte); result += try MobileTerminalInputFrame.decode(from: &buffer) }
        #expect(result == frames)
        #expect(buffer.isEmpty)
    }
    @Test func invalidLengthFailsWithoutUnboundedBuffering() {
        var buffer = Data([0xff, 0xff, 0xff, 0xff])
        #expect(throws: MobileTerminalInputFrame.FrameError.self) { try MobileTerminalInputFrame.decode(from: &buffer) }
    }
}
