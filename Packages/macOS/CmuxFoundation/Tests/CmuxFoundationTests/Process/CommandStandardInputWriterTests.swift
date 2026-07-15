import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct CommandStandardInputWriterTests {
    @Test func releasesPayloadAfterWritingWhileWriterRemainsAlive() throws {
        let byteCount = 1024 * 1024
        let pipe = Pipe()
        let releaseProbe = CommandStandardInputPayloadReleaseProbe()
        var payload = makePayload(byteCount: byteCount, releaseProbe: releaseProbe)
        let writer: CommandStandardInputWriter
        do {
            writer = try #require(CommandStandardInputWriter(
                fileHandle: pipe.fileHandleForWriting,
                data: payload
            ))
        }
        payload = Data()
        #expect(!releaseProbe.wasReleased)

        let output = pipe.fileHandleForReading.readDataToEndOfFile()

        #expect(output == Data(repeating: 0x41, count: byteCount))
        #expect(releaseProbe.wasReleased)
        withExtendedLifetime(writer) {}
    }

    private func makePayload(
        byteCount: Int,
        releaseProbe: CommandStandardInputPayloadReleaseProbe
    ) -> Data {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        bytes.initializeMemory(as: UInt8.self, repeating: 0x41, count: byteCount)
        return Data(
            bytesNoCopy: bytes,
            count: byteCount,
            deallocator: .custom { [releaseProbe] pointer, _ in
                releaseProbe.markReleased()
                pointer.deallocate()
            }
        )
    }
}
