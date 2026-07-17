import Darwin
import Foundation
import Testing
@testable import CmuxTerminalRenderTransport

@Suite struct TerminalRenderMessageChannelTests {
    @Test func preservesBinaryPayloadAndEmptyFrame() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let channel = TerminalRenderMessageChannel(
            readDescriptor: descriptors[0],
            writeDescriptor: descriptors[1]
        )

        let payload = Data([0, 1, 2, 3, 0xff])
        try channel.send(payload)
        #expect(channel.receive() == payload)
        try channel.send(Data())
        #expect(channel.receive() == Data())
    }

    @Test func rejectsOversizedOutboundFrame() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let channel = TerminalRenderMessageChannel(
            readDescriptor: descriptors[0],
            writeDescriptor: descriptors[1]
        )

        #expect(throws: TerminalRenderChannelError.frameTooLarge) {
            try channel.send(Data(count: TerminalRenderMessageChannel.maximumFrameLength + 1))
        }
    }
}
