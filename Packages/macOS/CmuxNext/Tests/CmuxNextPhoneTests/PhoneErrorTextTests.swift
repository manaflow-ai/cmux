import Testing
@testable import CmuxNextPhone

/// Failures in plain words (u9770: no raw errors for people who are not developers).
@Suite struct PhoneErrorTextTests {
    @Test(arguments: [
        ("You have not agreed to the Xcode license agreements", PhoneStrings.errorLicense),
        ("Error: No space left on device", PhoneStrings.errorDiskFull),
        ("xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH", PhoneStrings.errorNeedsXcode),
        ("The operation couldn't be completed. (NSURLErrorDomain error -1009.)", PhoneStrings.errorNetwork),
        ("Invalid device state", PhoneStrings.somethingWentWrong),
    ])
    func toolOutputBecomesANextStep(stderr: String, expected: String) {
        let text = PhoneErrorText(PhoneError.commandFailed(command: "simctl", status: 1, stderr: stderr))
        #expect(text.message == expected)
        #expect(text.detail.contains(stderr), "the raw text stays available as the detail")
    }

    @Test func missingToolsSayWhatToInstall() {
        #expect(PhoneErrorText(PhoneError.missingTool(.xcode)).message == PhoneStrings.errorNeedsXcode)
        #expect(PhoneErrorText(PhoneError.missingTool(.androidSDK)).message == PhoneStrings.errorNeedsAndroidStudio)
    }
}
