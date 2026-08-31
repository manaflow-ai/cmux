import CmuxRemoteSession
import Foundation
import Testing

@Suite struct RemoteTmuxSendKeysBatchBuilderTests {
    @Test func emptyInputProducesNoCommands() throws {
        let commands = try #require(
            RemoteTmuxSendKeysBatchBuilder.commands(paneID: 42, data: Data())
        )

        #expect(commands.isEmpty)
    }

    @Test func encodesLowercaseSpaceSeparatedHexBytes() throws {
        let commands = try #require(
            RemoteTmuxSendKeysBatchBuilder.commands(
                paneID: 42,
                data: Data([0x00, 0x0F, 0x10, 0xFF])
            )
        )

        #expect(commands == ["send-keys -t %42 -H 00 0f 10 ff"])
    }

    @Test func preservesAChunkedNonzeroBasedDataSliceInOrder() throws {
        let backing = Data((0..<8_205).map { UInt8($0 % 251) })
        let payloadStart = backing.index(backing.startIndex, offsetBy: 11)
        let payload = backing[payloadStart..<backing.endIndex]
        #expect(payload.startIndex == payloadStart)

        let commands = try #require(
            RemoteTmuxSendKeysBatchBuilder.commands(paneID: 7, data: payload)
        )

        #expect(commands.count > 1)
        #expect(commands.allSatisfy { $0.utf8.count < 30_000 })
        #expect(try decodedBytes(from: commands, paneID: 7) == Data(payload))
    }

    @Test func maximumInputFitsTheProductionWriterBudgetIncludingTerminators() throws {
        let maximumInput = Data(
            repeating: 0xFF,
            count: RemoteTmuxSendKeysBatchBuilder.maximumInputBytes
        )
        let commands = try #require(
            RemoteTmuxSendKeysBatchBuilder.commands(paneID: 7, data: maximumInput)
        )
        let encodedByteCount = commands.reduce(into: 0) { total, command in
            total += command.utf8.count + 1
        }

        #expect(!commands.isEmpty)
        #expect(encodedByteCount <= RemoteTmuxSendKeysBatchBuilder.writerPendingByteLimit)
        #expect(try decodedBytes(from: commands, paneID: 7) == maximumInput)
    }

    @Test func rejectsOneByteAboveMaximumInput() {
        let oversizedInput = Data(
            repeating: 0xFF,
            count: RemoteTmuxSendKeysBatchBuilder.maximumInputBytes + 1
        )

        #expect(
            RemoteTmuxSendKeysBatchBuilder.commands(paneID: 7, data: oversizedInput) == nil
        )
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
