import Foundation
import Testing
@testable import CmuxNextCloud

/// Crash program: the backend origins are literals that must parse (the /dev/null
/// stand-in never runs).
@Suite struct CloudCrashLiteralTests {
    @Test func originsParse() {
        #expect(CloudConfiguration.productionOrigin.absoluteString == "https://cmux.com")
        #expect(CloudConfiguration.stackOrigin.absoluteString == "https://api.stack-auth.com")
        #expect(CloudConfiguration.localDevelopmentOrigin.absoluteString == "http://localhost:3777")
    }
}
