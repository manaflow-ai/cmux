@testable import CmuxNextApp
import Foundation
import Testing

/// Promote to Template names its snapshot the way `cmux vm promote-template` did.
@MainActor
struct CloudTemplateTests {
    @Test func templateNameKeepsTwelveIDCharactersAndUnixSeconds() {
        let date = Date(timeIntervalSince1970: 1_790_000_000.75)
        #expect(CloudHandlers.templateName("0123456789abcdef-machine", at: date) == "template-0123456789ab-1790000000")
        #expect(CloudHandlers.templateName("short", at: date) == "template-short-1790000000")
    }
}
