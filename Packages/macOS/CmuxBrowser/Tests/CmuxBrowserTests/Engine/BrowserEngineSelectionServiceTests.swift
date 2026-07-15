import Foundation
import Testing
@testable import CmuxBrowser

@Suite @MainActor struct BrowserEngineSelectionServiceTests {
    private static func application(_ bundleIdentifier: String) -> BrowserApplication {
        BrowserApplication(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Test.app/Contents/MacOS/Test")
        )
    }

    @Test func automaticUsesLaunchServicesDefaultApplication() {
        let chromium = Self.application("com.google.Chrome")
        let service = BrowserEngineSelectionService(
            applicationProvider: BrowserApplicationProviderFake(defaultApplications: [chromium])
        )

        #expect(service.select(preference: .automatic) == BrowserEngineSelection(
            kind: .chromium,
            chromiumApplication: chromium
        ))
    }

    @Test func explicitChromiumUsesAnInstalledFallback() {
        let safari = Self.application("com.apple.Safari")
        let brave = Self.application("com.brave.Browser")
        let service = BrowserEngineSelectionService(
            applicationProvider: BrowserApplicationProviderFake(
                defaultApplications: [safari],
                chromiumApplications: [brave]
            )
        )

        #expect(service.select(preference: .chromium).chromiumApplication == brave)
    }

    @Test func restoredEngineOverridesCurrentPreference() {
        let service = BrowserEngineSelectionService(
            applicationProvider: BrowserApplicationProviderFake(defaultApplications: [])
        )

        #expect(service.select(preference: .chromium, restoredKind: .webKit).kind == .webKit)
        #expect(service.select(preference: .webKit, restoredKind: .chromium).kind == .chromium)
    }
}
