// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ManualClockTests {
    @Test func advancesMonotonically() {
        let c = ManualClock(start: 0)
        #expect(c.now() == 0)
        c.advance(by: 1.5)
        #expect(c.now() == 1.5)
        c.advance(by: 0.5)
        #expect(c.now() == 2.0)
    }
}
