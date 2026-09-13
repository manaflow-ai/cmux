import CmuxRemoteSession
import Foundation
import Testing

@Suite struct RemoteTmuxSendKeysBatchBuilderTests {
    private let builder = RemoteTmuxSendKeysBatchBuilder()

    @Test func emptyInputProducesNoCommands() throws {
        let commands = try #require(builder.commands(paneID: 42, data: Data()))

        #expect(commands.isEmpty)
    }

    @Test func encodesLowercaseSpaceSeparatedHexBytes() throws {
        let commands = try #require(
            builder.commands(paneID: 42, data: Data([0x00, 0x0F, 0x10, 0xFF]))
        )

        #expect(commands == ["send-keys -t %42 -H 00 0f 10 ff"])
    }

    @Test func preservesAChunkedNonzeroBasedDataSliceInOrder() throws {
        let backing = Data((0..<8_205).map { UInt8($0 % 251) })
        let payloadStart = backing.index(backing.startIndex, offsetBy: 11)
        let payload = backing[payloadStart..<backing.endIndex]
        #expect(payload.startIndex == payloadStart)

        let commands = try #require(builder.commands(paneID: 7, data: payload))

        #expect(commands.count > 1)
        #expect(commands.allSatisfy { $0.utf8.count < 30_000 })
        #expect(try decodedBytes(from: commands, paneID: 7) == Data(payload))
    }

    @Test func maximumInputFitsTheProductionWriterBudgetIncludingTerminators() throws {
        let maximumInput = Data(
            repeating: 0xFF,
            count: RemoteTmuxSendKeysBatchBuilder.defaultMaximumInputBytes
        )
        let commands = try #require(builder.commands(paneID: 7, data: maximumInput))
        let encodedByteCount = commands.reduce(into: 0) { total, command in
            total += command.utf8.count + 1
        }

        #expect(!commands.isEmpty)
        #expect(encodedByteCount <= builder.writerPendingByteLimit)
        #expect(try decodedBytes(from: commands, paneID: 7) == maximumInput)
    }

    @Test func rejectsOneByteAboveMaximumInput() {
        let oversizedInput = Data(
            repeating: 0xFF,
            count: RemoteTmuxSendKeysBatchBuilder.defaultMaximumInputBytes + 1
        )

        #expect(builder.commands(paneID: 7, data: oversizedInput) == nil)
    }

    @Test func injectedPolicyGovernsFramingAndAdmission() throws {
        let injected = RemoteTmuxSendKeysBatchBuilder(
            maximumInputBytes: 6,
            maximumBytesPerCommand: 2
        )
        let payload = Data([0x41, 0x42, 0x43, 0x44, 0x45, 0x46])

        let commands = try #require(injected.commands(paneID: 3, data: payload))

        #expect(commands == [
            "send-keys -t %3 -H 41 42",
            "send-keys -t %3 -H 43 44",
            "send-keys -t %3 -H 45 46",
        ])
        #expect(try decodedBytes(from: commands, paneID: 3) == payload)
        #expect(injected.commands(paneID: 3, data: payload + Data([0x47])) == nil)
    }

    @Test func writerBudgetCoversTheFramedBatchOfAMaximumInput() throws {
        let defaultPolicy = RemoteTmuxSendKeysBatchBuilder()
        #expect(defaultPolicy.writerPendingByteLimit == defaultPolicy.maximumInputBytes * 4)

        // Per-command framing dominates when chunks are tiny, so the four-bytes
        // -per-input-byte budget alone would under-size writer admission.
        let injected = RemoteTmuxSendKeysBatchBuilder(
            maximumInputBytes: 6,
            maximumBytesPerCommand: 2
        )
        let maximumInput = Data(repeating: 0x5A, count: injected.maximumInputBytes)
        let commands = try #require(injected.commands(paneID: 999_999, data: maximumInput))
        let framedByteCount = commands.reduce(into: 0) { total, command in
            total += command.utf8.count + 1
        }

        #expect(framedByteCount > injected.maximumInputBytes * 4)
        #expect(injected.writerPendingByteLimit >= framedByteCount)
        #expect(injected.writerPendingByteLimit >= injected.maximumFramedBatchByteCount)
    }
}

private func decodedBytes(from commands: [String], paneID: Int) throws -> Data {
    let prefix = "send-keys -t %\(paneID) -H "
    var decoded = Data()
    for command in commands {
        #expect(command.hasPrefix(prefix))
        for argument in command.dropFirst(prefix.count).split(separator: " ") {
            decoded.append(try #require(UInt8(argument, radix: 16)))
        }
    }
    return decoded
}
