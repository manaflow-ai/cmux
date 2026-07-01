import Foundation
import Testing
@testable import CmuxSidebarInterpreterClient

@Suite struct LengthPrefixedMessageChannelTests {
    @Test func roundTripsAFramedMessage() throws {
        let pipe = Pipe()
        let channel = LengthPrefixedMessageChannel(
            readFD: pipe.fileHandleForReading.fileDescriptor,
            writeFD: pipe.fileHandleForWriting.fileDescriptor
        )
        let payload = Data("hello, framed world".utf8)
        try channel.sendMessage(payload)
        #expect(channel.receiveMessage() == payload)
    }

    @Test func roundTripsAnEmptyMessage() throws {
        let pipe = Pipe()
        let channel = LengthPrefixedMessageChannel(
            readFD: pipe.fileHandleForReading.fileDescriptor,
            writeFD: pipe.fileHandleForWriting.fileDescriptor
        )
        try channel.sendMessage(Data())
        #expect(channel.receiveMessage() == Data())
    }

    @Test func returnsNilWhenWriterClosed() throws {
        let pipe = Pipe()
        let channel = LengthPrefixedMessageChannel(
            readFD: pipe.fileHandleForReading.fileDescriptor,
            writeFD: pipe.fileHandleForWriting.fileDescriptor
        )
        try pipe.fileHandleForWriting.close()
        #expect(channel.receiveMessage() == nil)
    }
}

@Suite struct LengthPrefixedFrameGuardTests {
    /// An inbound length header beyond the cap reads as end-of-stream instead
    /// of an allocation the peer controls.
    @Test func oversizedInboundHeaderReadsAsEOF() throws {
        let inbound = Pipe()
        let channel = LengthPrefixedMessageChannel(
            readFD: inbound.fileHandleForReading.fileDescriptor,
            writeFD: FileHandle.nullDevice.fileDescriptor
        )
        let oversize = UInt32(LengthPrefixedMessageChannel.maximumFrameLength) + 1
        var header = Data(count: 4)
        header[0] = UInt8((oversize >> 24) & 0xFF)
        header[1] = UInt8((oversize >> 16) & 0xFF)
        header[2] = UInt8((oversize >> 8) & 0xFF)
        header[3] = UInt8(oversize & 0xFF)
        try inbound.fileHandleForWriting.write(contentsOf: header)
        #expect(channel.receiveMessage() == nil)
    }

    /// An outbound payload beyond the cap throws instead of writing a frame
    /// the peer would reject.
    @Test func oversizedOutboundPayloadThrows() {
        let outbound = Pipe()
        let channel = LengthPrefixedMessageChannel(
            readFD: FileHandle.nullDevice.fileDescriptor,
            writeFD: outbound.fileHandleForWriting.fileDescriptor
        )
        let payload = Data(count: LengthPrefixedMessageChannel.maximumFrameLength + 1)
        #expect(throws: ChannelError.self) {
            try channel.sendMessage(payload)
        }
    }
}
