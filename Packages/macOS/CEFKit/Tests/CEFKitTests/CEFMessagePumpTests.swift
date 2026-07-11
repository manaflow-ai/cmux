import Foundation
import Testing

@testable import CEFKit

/// Regression for the permanent-wakeup class: the 30 Hz backstop must exist
/// only while demand (live browsers / pending creations / context init) is
/// present. Timer bookkeeping is pure Foundation; nothing here touches
/// libcef.
@Suite("CEFMessagePump backstop demand")
struct CEFMessagePumpBackstopTests {
    @Test @MainActor func backstopFollowsDemand() {
        let pump = CEFMessagePump()
        defer { pump.stop() }
        #expect(pump.backstopTimer == nil)
        pump.setBackstopDemand(true)
        #expect(pump.backstopTimer != nil, "demand must install the standing backstop")
        pump.setBackstopDemand(false)
        #expect(pump.backstopTimer == nil, "the backstop must stop when the last browser closes")
    }

    @Test @MainActor func scheduleWithoutDemandStaysOneShot() {
        let pump = CEFMessagePump()
        defer { pump.stop() }
        pump.schedule(afterMilliseconds: 5)
        #expect(pump.scheduledTimer != nil, "CEF-requested pumps are always honored")
        #expect(pump.backstopTimer == nil, "schedule requests alone must not start permanent wakeups")
    }

    @Test @MainActor func scheduleWithDemandKeepsBackstop() {
        let pump = CEFMessagePump()
        defer { pump.stop() }
        pump.setBackstopDemand(true)
        pump.schedule(afterMilliseconds: 5)
        #expect(pump.backstopTimer != nil)
        #expect(pump.scheduledTimer != nil)
    }
}
