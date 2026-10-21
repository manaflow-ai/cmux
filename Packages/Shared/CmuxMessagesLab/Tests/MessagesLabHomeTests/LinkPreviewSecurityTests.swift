@testable import MessagesLabHome
import Testing

@Suite struct LinkPreviewSecurityTests {
    @Test func noResultCanAuthorizeAnUnguardedSecondaryFetch() {
        #expect(!LinkPreviews.fallbackAllowed(nil))
    }
}
