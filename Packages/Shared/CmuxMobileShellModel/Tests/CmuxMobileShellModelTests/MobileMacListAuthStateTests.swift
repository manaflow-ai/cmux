import CmuxMobileShellModel
import Testing

@Suite
struct MobileMacListAuthStateTests {
    @Test
    func comparesReportedVersionToServerFloor() {
        let outdated = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.19+123",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(outdated.isOutdated)

        let current = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20+1",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!current.isOutdated)
    }

    @Test
    func unknownOrMalformedVersionsDoNotWarn() {
        let unknown = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: nil,
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!unknown.isOutdated)

        let malformed = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "nightly",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!malformed.isOutdated)
    }
}
