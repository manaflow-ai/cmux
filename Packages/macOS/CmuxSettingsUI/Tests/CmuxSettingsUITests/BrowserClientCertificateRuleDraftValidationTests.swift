import Testing

@testable import CmuxSettingsUI

struct BrowserClientCertificateRuleDraftValidationTests {
    @Test func acceptsEmptyAndCommentOnlyDrafts() {
        #expect(BrowserClientCertificateRuleDraftValidation.isValid("\n# managed example\n"))
    }

    @Test func rejectsIncompleteRuleBeforeItCanBeSaved() {
        #expect(!BrowserClientCertificateRuleDraftValidation.isValid("intranet.example.com ="))
        #expect(!BrowserClientCertificateRuleDraftValidation.isValid("intranet.example.com = 01AB23\nincomplete ="))
    }

    @Test func acceptsCompleteHostAndSerialRules() {
        #expect(
            BrowserClientCertificateRuleDraftValidation.isValid(
                "intranet.example.com\nintranet.example.com = 01:AB 23"
            )
        )
    }
}
