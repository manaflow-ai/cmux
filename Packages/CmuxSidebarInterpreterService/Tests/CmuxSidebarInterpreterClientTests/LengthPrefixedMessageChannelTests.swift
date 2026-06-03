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
