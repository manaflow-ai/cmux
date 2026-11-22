import Foundation
import Testing
@testable import CmuxNextAgentActivity

/// Crash program: the cmux:// page address is a literal that must parse.
@MainActor @Suite struct AgentActivityCrashLiteralTests {
    @Test func pageAddressParses() {
        #expect(AgentActivityPageAddress.url.absoluteString == AgentActivityPageAddress.string)
    }
}
