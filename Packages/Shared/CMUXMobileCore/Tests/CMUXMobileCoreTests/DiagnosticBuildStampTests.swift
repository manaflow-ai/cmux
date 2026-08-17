import Testing
@testable import CMUXMobileCore

@Suite struct DiagnosticBuildStampTests {
    @Test func includesSignedTagAndShaWithoutRuntimeInput() {
        let stamp = DiagnosticBuildStamp.make(infoDictionary: [
            "CFBundleName": "cmux",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CMUXDevTag": "netrel",
            "CMUXGitSHA": "0123456789abcdef",
        ])

        #expect(stamp == "cmux 1.2.3 (42) tag netrel sha 0123456789ab")
    }

    @Test func removesUnsafeBundleMetadata() {
        let stamp = DiagnosticBuildStamp.make(infoDictionary: [
            "CFBundleName": "cmux/unsafe",
            "CFBundleShortVersionString": "1\n2",
            "CFBundleVersion": "7",
            "CMUXDevTag": "tag with spaces",
            "CMUXGitSHA": "abcdef",
        ])

        #expect(!stamp.contains("/"))
        #expect(!stamp.contains("\n"))
        #expect(stamp.contains("sha abcdef"))
    }
}
