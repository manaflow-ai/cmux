import Testing
@testable import CmuxBrowserPanel

@Suite struct BrowserFirstResponderBypassTests {
    @Test func inactiveByDefault() {
        let bypass = BrowserFirstResponderBypass()
        #expect(bypass.isActive == false)
    }

    @Test func activeOnlyWithinBypass() {
        let bypass = BrowserFirstResponderBypass()
        #expect(bypass.isActive == false)
        bypass.withBypass {
            #expect(bypass.isActive == true)
        }
        #expect(bypass.isActive == false)
    }

    @Test func reentrantNestingStaysActiveUntilOutermostReturns() {
        let bypass = BrowserFirstResponderBypass()
        bypass.withBypass {
            #expect(bypass.isActive == true)
            bypass.withBypass {
                #expect(bypass.isActive == true)
            }
            #expect(bypass.isActive == true)
        }
        #expect(bypass.isActive == false)
    }

    @Test func passesThroughReturnValue() {
        let bypass = BrowserFirstResponderBypass()
        let result = bypass.withBypass { 42 }
        #expect(result == 42)
    }

    @Test func resetsAfterRepeatedUse() {
        let bypass = BrowserFirstResponderBypass()
        for _ in 0..<3 {
            bypass.withBypass {
                #expect(bypass.isActive == true)
            }
            #expect(bypass.isActive == false)
        }
    }
}
