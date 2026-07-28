import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareTerminalFrameCodecTests {
    private let epoch = UUID(
        uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
    )!

    @Test
    func `CMXS v1 baseline uses the canonical big endian header`() throws {
        let bytes = Data([0x00, 0xFF, 0x1B, 0x5B, 0x48, 0xC3, 0x28, 0x0A])
        let frame = try WorkspaceShareTerminalFrame(
            kind: .baseline,
            streamEpoch: epoch,
            sequenceStart: 0x0102_0304_0506_0708,
            sequenceEnd: 0x0102_0304_0506_0708,
            rows: 0x0102,
            columns: 0x0304,
            workspaceID: "ws",
            paneID: "pty",
            userID: nil,
            bytes: bytes
        )

        let encoded = try frame.encoded()

        #expect(WorkspaceShareTerminalFrame.wireVersion == 1)
        #expect(Array(encoded[0..<4]) == Array("CMXS".utf8))
        #expect(encoded[4] == 1)
        #expect(encoded[5] == 0x01)
        #expect(Array(encoded[6..<8]) == [0x00, 0x00])
        #expect(Array(encoded[8..<24]) == [
            0x00, 0x11, 0x22, 0x33,
            0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF,
        ])
        #expect(Array(encoded[24..<32]) == [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ])
        #expect(Array(encoded[32..<40]) == [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ])
        #expect(Array(encoded[40..<44]) == [0x01, 0x02, 0x03, 0x04])
        #expect(Array(encoded[44..<50]) == [
            0x00, 0x02,
            0x00, 0x03,
            0x00, 0x00,
        ])
        #expect(Array(encoded[50..<52]) == [0x00, 0x00])
        #expect(Array(encoded[52..<56]) == [0x00, 0x00, 0x00, 0x08])
        #expect(
            Data(encoded[56...])
                == Data("wspty".utf8) + bytes
        )
        #expect(try WorkspaceShareTerminalFrame.decode(encoded) == frame)
        #expect(try WorkspaceShareTerminalFrame.decode(encoded).bytes == bytes)
    }

    @Test
    func `Baseline fixes the raw cursor while output advances by opaque byte count`() throws {
        let baseline = try WorkspaceShareTerminalFrame(
            kind: .baseline,
            streamEpoch: epoch,
            sequenceStart: 4_096,
            sequenceEnd: 4_096,
            rows: 24,
            columns: 80,
            workspaceID: "workspace",
            paneID: "pane",
            userID: nil,
            bytes: Data([0x1B, 0x63, 0xFF])
        )
        let firstOutput = try WorkspaceShareTerminalFrame(
            kind: .output,
            streamEpoch: epoch,
            sequenceStart: 4_096,
            sequenceEnd: 4_099,
            rows: 24,
            columns: 80,
            workspaceID: "workspace",
            paneID: "pane",
            userID: nil,
            bytes: Data([0x00, 0xFE, 0x41])
        )
        let secondOutput = try WorkspaceShareTerminalFrame(
            kind: .output,
            streamEpoch: epoch,
            sequenceStart: 4_099,
            sequenceEnd: 4_101,
            rows: 24,
            columns: 80,
            workspaceID: "workspace",
            paneID: "pane",
            userID: nil,
            bytes: Data([0xC3, 0x28])
        )

        #expect(try WorkspaceShareTerminalFrame.decode(baseline.encoded()) == baseline)
        #expect(try WorkspaceShareTerminalFrame.decode(firstOutput.encoded()) == firstOutput)
        #expect(try WorkspaceShareTerminalFrame.decode(secondOutput.encoded()) == secondOutput)
        #expect(baseline.sequenceStart == baseline.sequenceEnd)
        #expect(firstOutput.sequenceEnd == firstOutput.sequenceStart + 3)
        #expect(secondOutput.sequenceStart == firstOutput.sequenceEnd)
    }

    @Test
    func `Guest and authoritative forwarded input use their canonical shapes`() throws {
        let opaqueInput = Data([0x03, 0x00, 0xFF])
        let guestInput = try WorkspaceShareTerminalFrame(
            kind: .input,
            streamEpoch: nil,
            sequenceStart: 0,
            sequenceEnd: 0,
            rows: 0,
            columns: 0,
            workspaceID: "workspace",
            paneID: "pane",
            userID: nil,
            bytes: opaqueInput
        )
        let forwardedInput = try WorkspaceShareTerminalFrame(
            kind: .forwardedInput,
            streamEpoch: nil,
            sequenceStart: 0,
            sequenceEnd: 0,
            rows: 0,
            columns: 0,
            workspaceID: "workspace",
            paneID: "pane",
            userID: "relay-user",
            bytes: opaqueInput
        )

        let encodedGuest = try guestInput.encoded()
        let encodedForwarded = try forwardedInput.encoded()

        #expect(encodedGuest[5] == 0x03)
        #expect(Array(encodedGuest[8..<24]) == Array(repeating: 0, count: 16))
        #expect(Array(encodedGuest[24..<44]) == Array(repeating: 0, count: 20))
        #expect(Array(encodedGuest[48..<50]) == [0x00, 0x00])
        #expect(try WorkspaceShareTerminalFrame.decode(encodedGuest) == guestInput)

        #expect(encodedForwarded[5] == 0x04)
        #expect(Array(encodedForwarded[8..<24]) == Array(repeating: 0, count: 16))
        #expect(Array(encodedForwarded[24..<44]) == Array(repeating: 0, count: 20))
        #expect(Array(encodedForwarded[48..<50]) == [0x00, 0x0A])
        #expect(
            try WorkspaceShareTerminalFrame.decode(encodedForwarded)
                == forwardedInput
        )
        #expect(
            try WorkspaceShareTerminalFrame.decode(encodedForwarded).userID
                == "relay-user"
        )
        #expect(
            try WorkspaceShareTerminalFrame.decode(encodedForwarded).bytes
                == opaqueInput
        )
    }

    @Test
    func `Malformed magic version kind flags reserved lengths and truncation are rejected`() throws {
        let valid = try WorkspaceShareTerminalFrame(
            kind: .baseline,
            streamEpoch: epoch,
            sequenceStart: 10,
            sequenceEnd: 10,
            rows: 24,
            columns: 80,
            workspaceID: "workspace",
            paneID: "pane",
            userID: nil,
            bytes: Data([0x41, 0x42, 0x43])
        ).encoded()

        for end in 0..<valid.count {
            #expect(throws: (any Error).self) {
                try WorkspaceShareTerminalFrame.decode(
                    Data(valid.prefix(end))
                )
            }
        }

        for index in 0..<4 {
            var malformedMagic = valid
            malformedMagic[index] ^= 0xFF
            #expect(throws: (any Error).self) {
                try WorkspaceShareTerminalFrame.decode(malformedMagic)
            }
        }

        var unknownVersion = valid
        unknownVersion[4] = 0xFF
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(unknownVersion)
        }

        var unknownKind = valid
        unknownKind[5] = 0xFF
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(unknownKind)
        }

        var unsupportedFlags = valid
        unsupportedFlags[7] = 0x01
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(unsupportedFlags)
        }

        var nonzeroReserved = valid
        nonzeroReserved[51] = 0x01
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(nonzeroReserved)
        }

        var wrongPayloadLength = valid
        wrongPayloadLength[55] += 1
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(wrongPayloadLength)
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame.decode(valid + Data([0x00]))
        }
    }

    @Test
    func `Semantic gap overflow geometry and identity violations are rejected`() {
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .baseline,
                streamEpoch: epoch,
                sequenceStart: 10,
                sequenceEnd: 11,
                rows: 24,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .output,
                streamEpoch: epoch,
                sequenceStart: 10,
                sequenceEnd: 12,
                rows: 24,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .output,
                streamEpoch: epoch,
                sequenceStart: UInt64.max,
                sequenceEnd: UInt64.max,
                rows: 24,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .baseline,
                streamEpoch: nil,
                sequenceStart: 0,
                sequenceEnd: 0,
                rows: 24,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .baseline,
                streamEpoch: epoch,
                sequenceStart: 0,
                sequenceEnd: 0,
                rows: 0,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .input,
                streamEpoch: epoch,
                sequenceStart: 1,
                sequenceEnd: 1,
                rows: 24,
                columns: 80,
                workspaceID: "workspace",
                paneID: "pane",
                userID: "spoofed-user",
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .forwardedInput,
                streamEpoch: nil,
                sequenceStart: 0,
                sequenceEnd: 0,
                rows: 0,
                columns: 0,
                workspaceID: "workspace",
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
        #expect(throws: (any Error).self) {
            try WorkspaceShareTerminalFrame(
                kind: .input,
                streamEpoch: nil,
                sequenceStart: 0,
                sequenceEnd: 0,
                rows: 0,
                columns: 0,
                workspaceID: String(repeating: "w", count: 65_536),
                paneID: "pane",
                userID: nil,
                bytes: Data([0x41])
            )
        }
    }
}
