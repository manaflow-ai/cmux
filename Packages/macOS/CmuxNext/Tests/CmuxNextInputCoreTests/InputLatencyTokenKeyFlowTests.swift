import CmuxNextInputCore
import Testing

/// A terminal key's latency slot as its daemon `send`'s flow: the flow names the slot again, is never
/// 0, and never equals a typing-probe flow (a pid in bits 32-62).
struct InputLatencyTokenKeyFlowTests {
    @Test func aSlotsFlowNamesItAgain() {
        for raw: UInt32 in [0, 1, 0x00FF_FF07, .max] {
            let token = InputLatencyToken(rawValue: raw)
            #expect(token.keyFlow != 0)
            #expect(InputLatencyToken(keyFlow: token.keyFlow) == token)
        }
    }

    @Test func otherFlowsNameNoSlot() {
        #expect(InputLatencyToken(keyFlow: 0) == nil)
        #expect(InputLatencyToken(keyFlow: 7) == nil)
        let probeFlow: UInt64 = 0x7FFF_FFFF << 32 | 7  // the largest pid, press 7
        #expect(InputLatencyToken(keyFlow: probeFlow) == nil)
    }
}
