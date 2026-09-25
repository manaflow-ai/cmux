import Testing
import CmuxTerminalCore

@Suite struct TerminalCommittedIMEReturnInputSourcePolicyTests {
    private let policy = TerminalCommittedIMEReturnInputSourcePolicy()

    @Test func appleKoreanSourceQualifiesByIdWithoutLanguageMetadata() {
        #expect(policy.shouldForwardReturn(
            sourceId: "com.apple.inputmethod.Korean.2SetKorean",
            languages: []
        ))
    }

    @Test func thirdPartyKoreanSourceQualifiesByPrimaryLanguageSnapshot() {
        #expect(policy.shouldForwardReturn(
            sourceId: "org.youknowone.inputmethod.Gureum.han2",
            languages: ["ko"]
        ))
    }

    @Test func japaneseAndChineseSourcesDoNotQualify() {
        #expect(!policy.shouldForwardReturn(
            sourceId: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        ))
        #expect(!policy.shouldForwardReturn(
            sourceId: "com.apple.inputmethod.SCIM.ITABC",
            languages: ["zh-Hans"]
        ))
    }

    @Test func onlyPrimaryLanguageCounts() {
        #expect(!policy.shouldForwardReturn(
            sourceId: "org.example.inputmethod.Multi",
            languages: ["ja", "ko"]
        ))
    }

    @Test func missingSourceIdNeverQualifies() {
        #expect(!policy.shouldForwardReturn(sourceId: nil, languages: ["ko"]))
    }
}
