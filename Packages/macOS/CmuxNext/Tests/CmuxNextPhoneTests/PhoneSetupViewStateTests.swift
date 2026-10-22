import Testing
@testable import CmuxNextPhone

/// The setup screen's content (u9770): every step says what to do and has a button for it.
@Suite struct PhoneSetupViewStateTests {
    @Test(arguments: [PhoneSetupStep.installXcode, .finishXcode, .downloadIOS, .createIPhone])
    func everyStepHasWordsAndANextButton(step: PhoneSetupStep) {
        let state = PhoneSetupViewState(status: PhoneSetupStatus(step: step, xcodeApp: "/Applications/Xcode.app"), activity: nil, failure: nil)
        #expect(!state.title.isEmpty)
        #expect(!state.body.isEmpty)
        #expect(state.primary != nil, "no dead ends: each step has a button")
        #expect(state.rows.filter(\.current).map(\.title) == [PhoneSetupViewState.title(of: step)])
        #expect(state.rows.prefix { !$0.current }.allSatisfy(\.done))
    }

    @Test func installingXcodeOpensTheAppStoreAndExplainsCommandLineTools() {
        let state = PhoneSetupViewState(status: PhoneSetupStatus(step: .installXcode, hasOnlyCommandLineTools: true), activity: nil, failure: nil)
        #expect(state.primary?.action == .openAppStore)
        #expect(state.primary?.action.url?.scheme == "macappstore")
        #expect(state.secondary?.action == .openXcodeWebsite)
        #expect(state.body.contains(PhoneStrings.setupCommandLineToolsNote))
    }

    @Test func aRunningDownloadShowsItsProgressAndCanBeCancelled() {
        let state = PhoneSetupViewState(status: PhoneSetupStatus(step: .downloadIOS),
                                        activity: .downloading(PhoneSetupProgress(fraction: 0.42, amount: "3.5 GB of 8.4 GB")), failure: nil)
        #expect(state.progress == 0.42)
        #expect(state.progressText == PhoneStrings.setupDownloading(percent: 42) + " (3.5 GB of 8.4 GB)")
        #expect(state.primary?.action == .cancelDownload)
    }

    @Test func aFailureShowsInPlainWordsWithTheRawTextAsDetail() {
        let failure = PhoneErrorText(PhoneError.commandFailed(command: "xcodebuild", status: 1, stderr: "NSURLErrorDomain -1009 offline"))
        let state = PhoneSetupViewState(status: PhoneSetupStatus(step: .downloadIOS), activity: nil, failure: failure)
        #expect(state.failure == PhoneStrings.errorNetwork)
        #expect(state.failureDetail?.contains("NSURLErrorDomain") == true)
        #expect(state.primary?.action == .downloadIOS, "after a failure the same step can be tried again")
    }
}
