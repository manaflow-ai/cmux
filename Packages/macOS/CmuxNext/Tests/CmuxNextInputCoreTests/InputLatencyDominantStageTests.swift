import CmuxNextInputCore
import Testing

/// An input's longest stage interval (p04-input-009, the latency HUD's input rows): the same
/// intervals the ledger files under each stage, by time not declaration, without
/// `lastGenerated`, and none for an input that reached fewer than two stages. Run:
/// `swift test --filter InputLatencyDominantStageTests`.
struct InputLatencyDominantStageTests {
    private static let ms: UInt64 = 1_000_000

    @Test func theLongestIntervalWinsAndNamesBothEnds() {
        var slot = InputLatencySlot(kind: .keyPress, target: .chromiumPage, entrypoint: .person)
        slot.generated = 100 * Self.ms
        slot.arrivedMain = 101 * Self.ms
        slot.dispatchEnd = 103 * Self.ms
        slot.contentSubmitted = 112 * Self.ms
        slot.presented = 115 * Self.ms
        #expect(slot.dominantStage == InputLatencyDominantStage(from: .dispatchEnd, to: .contentSubmitted, nanos: 9 * Self.ms))
    }

    @Test func stagesFollowEachOtherByTimeNotDeclaration() {
        // A terminal key's echo comes back before its frame is submitted.
        var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person)
        slot.generated = 100 * Self.ms
        slot.dispatchEnd = 101 * Self.ms
        slot.contentSubmitted = 110 * Self.ms
        slot.daemonReceived = 102 * Self.ms
        slot.echoSent = 108 * Self.ms
        slot.presented = 111 * Self.ms
        #expect(slot.dominantStage == InputLatencyDominantStage(from: .daemonReceived, to: .echoSent, nanos: 6 * Self.ms))
    }

    @Test func lastGeneratedIsNotAStage() {
        var slot = InputLatencySlot(kind: .scrollUpdate, target: .chromiumPage, entrypoint: .person)
        slot.generated = 100 * Self.ms
        slot.lastGenerated = 130 * Self.ms
        slot.presented = 140 * Self.ms
        #expect(slot.dominantStage == InputLatencyDominantStage(from: .generated, to: .presented, nanos: 40 * Self.ms))
    }

    @Test func fewerThanTwoStagesHaveNoInterval() {
        var slot = InputLatencySlot(kind: .mousePress, target: .sidebar, entrypoint: .person)
        #expect(slot.dominantStage == nil)
        slot.generated = 100 * Self.ms
        #expect(slot.dominantStage == nil)
    }
}
