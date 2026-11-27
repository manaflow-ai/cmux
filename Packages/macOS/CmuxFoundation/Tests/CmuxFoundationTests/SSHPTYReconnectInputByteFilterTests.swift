import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH PTY reconnect input byte filter")
struct SSHPTYReconnectInputByteFilterTests {
    @Test func keepsFilteringAcrossProbeOnlyReadsUntilFirstNormalInput() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R\u{1B}[?1;2c\u{1B}[?0u".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]12;rgb:ffff/ffff/ffff\u{07}".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)

        let laterReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(laterReply) == laterReply)
    }

    @Test func keepsFilteringAtIdleProbeBoundaryUntilNormalInput() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R".utf8)) == Data())
        #expect(filter.isFilteringAtProbeBoundary)

        let liveReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(liveReply) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)
        #expect(filter.filter(liveReply) == liveReply)
    }

    @Test func stopFilteringPreservesLaterProbeLikeInput() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R".utf8)) == Data())
        #expect(filter.stopFiltering() == Data())

        let liveReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(liveReply) == liveReply)
    }

    @Test func buffersRecognizedSplitOSCColorReplyWithinInitialDrain() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("/f0f0\u{1B}\\".utf8) + normalInput) == normalInput)
    }

    @Test func buffersOSCColorReplySplitBeforeCommandSeparator() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]1".utf8)) == Data())
        #expect(filter.filter(Data("2".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data(";rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func buffersInitialEscapeUntilProbeContinuationArrives() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func passesThroughAmbiguousEscapeAfterNonProbeContinuation() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.filter(Data("x".utf8)) == Data("\u{1B}x".utf8))

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }

    @Test func stripsQueuedFocusReportsAndEOTBeforeFreshInput() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let queuedWakeInput = Data([0x04])
            + Data("\u{1B}[I\u{1B}[O\u{1B}[I".utf8)
        #expect(filter.filter(queuedWakeInput) == Data())

        let freshControlCAndEnter = Data([0x03, 0x0D])
        #expect(filter.filter(freshControlCAndEnter) == freshControlCAndEnter)
    }

    @Test("strips XTVERSION DCS replies alongside CSI replies")
    func stripsXtversionReply() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let replies = Data((
            "\u{1B}P>|ghostty 1.3.2-HEAD\u{1B}\\" +
            "\u{1B}[?62;22;52c" +
            "\u{1B}[?2026;2$y"
        ).utf8)

        #expect(filter.filter(replies).isEmpty)
        #expect(filter.isFilteringActive)
    }

    @Test("passes through a mismatching DCS prefix without waiting")
    func passesThroughMismatchingDCSPrefix() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let input = Data("\u{1B}Px".utf8)

        #expect(filter.filter(input) == input)
        #expect(!filter.isFilteringActive)
    }

    @Test func stopsFilteringAndForwardsPendingInputWhenNoContinuationArrives() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.hasPendingInput)
        #expect(filter.stopFiltering() == escape)

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }

    @Test func stopsFilteringWhenAnIncompleteSequenceExceedsTheBuffer() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let oversized = Data("\u{1B}]11;rgb:".utf8) + Data(repeating: 0x61, count: 600)

        #expect(filter.filter(oversized) == oversized)
        #expect(!filter.isFilteringActive)
    }

    @Test func seededSplitFuzzPreservesNonProbeBytes() {
        var seed: UInt64 = 0x7708
        let probes = [
            Data("\u{1B}[1;1R".utf8),
            Data("\u{1B}[?1;2c".utf8),
            Data("\u{1B}[?0u".utf8),
            Data("\u{1B}[4$y".utf8),
            Data("\u{1B}]10;rgb:ffff/ffff/ffff\u{07}".utf8),
            Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{1B}\\".utf8),
        ]
        let keys = [
            Data("plain text\n".utf8),
            Data("\u{1B}[A".utf8),
            Data("\u{1B}x".utf8),
            Data("\u{1B}[13;2u".utf8),
            Data("\u{1B}[200~paste\u{1B}[201~".utf8),
            Data([0x1B]),
        ]

        for index in 0..<128 {
            var filter = SSHPTYReconnectInputByteFilter(enabled: true)
            var segments: [(data: Data, isKey: Bool)] = []
            for _ in 0..<(1 + Int(nextRandom(&seed) % 4)) {
                segments.append((probes[Int(nextRandom(&seed) % UInt64(probes.count))], false))
            }
            for _ in 0..<(1 + Int(nextRandom(&seed) % 2)) {
                let key = keys[Int(nextRandom(&seed) % UInt64(keys.count))]
                let position = Int(nextRandom(&seed) % UInt64(segments.count + 1))
                segments.insert((key, true), at: position)
            }

            var input = Data()
            var expected = Data()
            var stripping = true
            for segment in segments {
                input.append(segment.data)
                if segment.isKey {
                    stripping = false
                }
                if !segment.isKey && stripping {
                    continue
                }
                expected.append(segment.data)
            }

            var output = Data()
            var cursor = 0
            while cursor < input.count {
                let remaining = input.count - cursor
                let step = 1 + Int(nextRandom(&seed) % UInt64(min(7, remaining)))
                output.append(filter.filter(Data(input[cursor..<(cursor + step)])))
                cursor += step
            }
            output.append(filter.finish())
            #expect(output == expected, "seed 0x7708 case \(index)")
        }
    }

    private func nextRandom(_ seed: inout UInt64) -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}
