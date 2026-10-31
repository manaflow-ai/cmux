import CmuxNextBrowserImport
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Import from Browser asks for each browser's profile folder before it reads
/// anything there (Zen's flow: the open panel at the folder, a security-scoped
/// bookmark kept per browser). Passwords get one explainer right before the
/// Keychain prompt, and a CSV import stands in when the Keychain key is not
/// allowed or the build cannot read saved passwords.
@MainActor @Suite(.serialized) struct BrowserImportFolderGrantTests {
    // MARK: Grants on disk

    /// A home with one Chrome profile (`Default`, with bookmarks).
    private static func chromeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "folder-grant-\(UUID().uuidString)", directoryHint: .isDirectory)
        let chrome = home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
        let profile = chrome.appending(path: "Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let state = #"{"profile":{"info_cache":{"Default":{"name":"Work"}},"profiles_order":["Default"]}}"#
        try Data(state.utf8).write(to: chrome.appending(path: "Local State"))
        try Data(#"{"roots":{}}"#.utf8).write(to: profile.appending(path: "Bookmarks"))
        return home
    }

    private static func grants(_ home: URL) -> BrowserFolderGrants {
        BrowserFolderGrants(environment: ImportEnvironment(homeDirectory: home, locateApp: { _ in nil }), store: MemoryBrowserFolderGrantStore())
    }

    @Test func aBrowserWithoutAGrantIsListedButNotRead() throws {
        let home = try Self.chromeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grants = Self.grants(home)

        #expect(grants.awaiting().contains(.chrome))
        #expect(!grants.detect().contains { $0.browser == .chrome })
        #expect(grants.folder(.chrome).path.hasSuffix("Library/Application Support/Google/Chrome"))
    }

    @Test func onlyTheBrowsersOwnFolderGrantsAccess() throws {
        let home = try Self.chromeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grants = Self.grants(home)

        // The parent folder, or a profile inside, is not the grant the panel asked for.
        #expect(throws: BrowserFolderGrants.GrantError.self) {
            try grants.grant(home.appending(path: "Library/Application Support", directoryHint: .isDirectory), for: .chrome)
        }
        #expect(throws: BrowserFolderGrants.GrantError.self) {
            try grants.grant(grants.folder(.chrome).appending(path: "Default", directoryHint: .isDirectory), for: .chrome)
        }
        #expect(!grants.isGranted(.chrome))

        try grants.grant(grants.folder(.chrome), for: .chrome)
        #expect(grants.isGranted(.chrome))
        #expect(!grants.awaiting().contains(.chrome))
        let chrome = try #require(grants.detect().first { $0.browser == .chrome })
        #expect(chrome.profiles.map(\.displayName) == ["Work"])

        grants.revoke(.chrome)
        #expect(!grants.isGranted(.chrome))
        #expect(grants.awaiting().contains(.chrome))
    }

    @Test func aGrantSurvivesANewStoreReader() throws {
        let home = try Self.chromeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = MemoryBrowserFolderGrantStore()
        let environment = ImportEnvironment(homeDirectory: home, locateApp: { _ in nil })
        try BrowserFolderGrants(environment: environment, store: store).grant(
            environment.dataDirectory(.chrome), for: .chrome)

        // The bookmark is what is kept: a later launch resolves it.
        #expect(BrowserFolderGrants(environment: environment, store: store).isGranted(.chrome))
    }

    // MARK: The step

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private static func profile(_ browser: ImportBrowser, passwords: DataAvailability) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: browser, directoryName: "Default", displayName: "Work",
                             path: URL(fileURLWithPath: "/tmp/\(browser.rawValue)/Default"),
                             availability: [.bookmarks: .available, .history: .available, .passwords: passwords])
    }

    @Test func continueOpensThePanelForThatBrowserThenLooksAgain() async {
        let services = MockOnboardingServices()
        services.awaitingAccess = [.chrome]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }
        #expect(step.awaitingAccess == [.chrome])

        step.askAccess(.chrome)
        #expect(step.phase == .explainingAccess(.chrome))
        #expect(onboarding.primaryTitle == OnboardingStrings.continueTitle)

        // The grant is made: the browser's profiles are read now.
        services.grantsAccess = true
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .absent)])]
        services.awaitingAccess = []
        onboarding.next()
        await Self.until { step.phase == .ready && !step.profiles.isEmpty }
        #expect(services.accessRequests == [.chrome])
        #expect(services.detections == 2)
        #expect(step.awaitingAccess.isEmpty)
        #expect(step.profiles.map(\.browser) == [.chrome])
    }

    @Test func cancelOrARefusedPanelReadsNothing() async {
        let services = MockOnboardingServices()
        services.awaitingAccess = [.chrome]
        let step = OnboardingModel(services: services, step: .importData).importer
        step.detect()
        await Self.until { step.phase == .ready }

        step.askAccess(.chrome)
        step.cancelAccess()
        #expect(step.phase == .ready)
        #expect(services.accessRequests.isEmpty)

        step.askAccess(.chrome)
        services.grantsAccess = false
        step.continueAccess()
        await Self.until { services.accessRequests == [.chrome] && !step.requestingAccess }
        // Still on the explainer, saying the folder was not allowed; nothing detected again.
        #expect(step.phase == .explainingAccess(.chrome))
        #expect(step.accessNotGranted)
        #expect(services.detections == 1)
    }

    @Test func theKeychainExplainerComesRightBeforePasswordsAreRead() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .available)])]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }

        onboarding.next()
        #expect(step.isConfirmingPasswords)
        #expect(onboarding.primaryTitle == OnboardingStrings.beginImporting)
        #expect(onboarding.skipTitle == OnboardingStrings.skipImporting)
        #expect(step.passwordKeychainItems == ["Chrome Safe Storage"])
        #expect(services.plans.isEmpty)
    }

    @Test func backAndProgressOnTheFolderExplainer() async {
        let services = MockOnboardingServices()
        services.awaitingAccess = [.chrome]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }
        #expect(!onboarding.canGoBack)
        #expect(onboarding.flowProgress == nil)

        step.askAccess(.chrome)
        #expect(onboarding.canGoBack)
        #expect(onboarding.flowProgress == 0.5)
        onboarding.goBack()
        #expect(step.phase == .ready)
        #expect(services.accessRequests.isEmpty)
        #expect(!onboarding.canGoBack)
    }

    @Test func backAndProgressOnTheKeychainExplainer() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .available)])]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }

        onboarding.next()
        #expect(step.isConfirmingPasswords)
        #expect(onboarding.canGoBack)
        #expect(onboarding.flowProgress == 0.75)
        onboarding.goBack()
        #expect(step.phase == .ready)
        #expect(services.plans.isEmpty)
        #expect(services.authorizationReasons.isEmpty)
    }

    @Test func noBackWhileTouchIDIsUp() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.holdsAuthorization = true
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .available)])]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }
        onboarding.next()
        // Begin Importing is a second click, not the first one repeated (`justStarted`).
        await Self.until { !step.justStarted }
        onboarding.next()
        await Self.until { services.authorizationReasons.count == 1 }
        #expect(services.authorizationReasons.count == 1)
        #expect(!onboarding.canGoBack)
        services.answerAuthorizations()
    }

    @Test func skipImportingWhileTouchIDIsUpReadsNothing() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.holdsAuthorization = true
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .available)])]
        let onboarding = OnboardingModel(services: services, step: .importData)
        let step = onboarding.importer
        step.detect()
        await Self.until { step.phase == .ready }

        onboarding.next()
        await Self.until { !step.justStarted }
        onboarding.next()
        await Self.until { services.authorizationReasons.count == 1 }
        #expect(services.authorizationReasons.count == 1, "the Touch ID sheet is up")
        // Skip Importing (or Escape) while the Touch ID sheet is up, then Touch ID succeeds.
        onboarding.skipStep()
        services.answerAuthorizations()
        await Self.until({ !services.plans.isEmpty }, within: .milliseconds(300))
        #expect(services.plans.isEmpty)
        #expect(!step.isConfirmingPasswords)
    }

    @Test func cancellingAllowAccessAfterAnImportKeepsItsSummary() async {
        let services = MockOnboardingServices()
        services.awaitingAccess = [.firefox]
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .absent)])]
        let step = OnboardingModel(services: services, step: .importData).importer
        step.detect()
        await Self.until { step.phase == .ready }
        step.start()
        await Self.until { if case .finished = step.phase { true } else { false } }
        let finished = step.phase
        guard case .finished = finished else {
            Issue.record("the import did not finish: \(finished)")
            return
        }

        step.askAccess(.firefox)
        #expect(step.phase == .explainingAccess(.firefox))
        step.cancelAccess()
        #expect(step.phase == finished)
    }

    @Test func aRefusedKeychainKeyOffersTheCSVImport() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.passwordAuthorization = false
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [Self.profile(.chrome, passwords: .available)])]
        let step = OnboardingModel(services: services, step: .importData).importer
        step.detect()
        await Self.until { step.phase == .ready }
        #expect(!step.offersPasswordCSV)

        step.start()
        step.start()
        await Self.until { step.authorizationDenied }
        #expect(step.offersPasswordCSV)
        step.importPasswordsFromCSV()
        #expect(services.csvImports == [nil])
    }

    @Test func aBuildThatCannotReadPasswordsOffersTheCSVImport() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        // The readers are compiled out: the profile's passwords are export-only.
        services.sources = [BrowserSource(browser: .chrome, appURL: nil,
                                          profiles: [Self.profile(.chrome, passwords: .unsupported(.exportFromSource))])]
        let step = OnboardingModel(services: services, step: .importData).importer
        step.detect()
        await Self.until { step.phase == .ready }
        #expect(!step.kindChoices.contains(.passwords))
        #expect(step.offersPasswordCSV)
    }
}
