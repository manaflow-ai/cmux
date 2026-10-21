import CmuxNextBrowserImport
import Foundation
@testable import CmuxNextOnboarding
import Testing

/// Profiles line up between browsers: each Chrome profile's color and picture
/// come with it, a row can go into an existing cmux profile, and importing a
/// source again into another profile moves it rather than keeping two copies.
@Suite(.serialized) struct BrowserImportProfileLookTests {
    /// Records each profile the importer asks for.
    private actor Provisioning: BrowserProfileProvisioning {
        private(set) var made: [(id: String, name: String, look: SourceProfileLook)] = []
        func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String {
            made.append((id, name, look))
            return id
        }
    }

    private struct Discard: ImportDestination {
        func commit(_ batch: ImportBatch) async throws {}
    }

    private static func chromeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "profile-look-\(UUID().uuidString)", directoryHint: .isDirectory)
        let chrome = home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
        for folder in ["Default", "Profile 1"] {
            let profile = chrome.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data(#"{"roots":{}}"#.utf8).write(to: profile.appending(path: "Bookmarks"))
        }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: chrome.appending(path: "Profile 1/Google Profile Picture.png"))
        // -15043608 is 0xFF1A73E8 as Chromium's signed ARGB int; the seed wins over the highlight.
        let state = #"""
        {"profile":{"profiles_order":["Default","Profile 1"],"info_cache":{
          "Default":{"name":"Personal","profile_highlight_color":-2543579},
          "Profile 1":{"name":"Work","profile_color_seed":-15043608,"profile_highlight_color":-2543579,
                       "gaia_picture_file_name":"Google Profile Picture.png"}}}}
        """#
        try Data(state.utf8).write(to: chrome.appending(path: "Local State"))
        return home
    }

    @Test func chromeProfilesCarryTheirColorAndPicture() throws {
        let home = try Self.chromeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = try #require(BrowserSourceDetector(environment: ImportEnvironment(homeDirectory: home, locateApp: { _ in nil }))
            .detect(.chrome))
        let personal = try #require(chrome.profiles.first { $0.displayName == "Personal" })
        let work = try #require(chrome.profiles.first { $0.displayName == "Work" })
        #expect(personal.color == 0xD9_3025)
        #expect(personal.avatar == nil)
        #expect(work.color == 0x1A_73E8)
        #expect(work.avatar?.lastPathComponent == "Google Profile Picture.png")
    }

    @Test func eachSourceGetsAMatchingProfileUnlessARowPicksOne() async throws {
        let home = try Self.chromeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = try #require(BrowserSourceDetector(environment: ImportEnvironment(homeDirectory: home, locateApp: { _ in nil }))
            .detect(.chrome))
        let personal = try #require(chrome.profiles.first { $0.displayName == "Personal" })
        let work = try #require(chrome.profiles.first { $0.displayName == "Work" })
        let provisioning = Provisioning()
        let plan = ImportPlan(items: [ImportPlan.Item(profile: personal, kinds: [.bookmarks], target: "existing"),
                                      ImportPlan.Item(profile: work, kinds: [.bookmarks])])
        let summary = try await BrowserImporter(provisioning: provisioning).run(plan, into: Discard()) { _ in }

        let made = await provisioning.made
        #expect(made.map(\.name) == ["Google Chrome · Work"])
        #expect(made.first?.look == SourceProfileLook(work))
        #expect(summary.batches.map(\.source.targetProfileID).first == "existing")
    }

    @Test func importingASourceIntoAnotherProfileMovesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "import-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedDataStore(directory: directory)
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Chrome",
                                                           proposedProfileID: "p1", targetProfileID: "first"), kinds: [.history])
        batch.history = [ImportedHistoryEntry(url: URL(fileURLWithPath: "/"), title: "Example", visitCount: 1, lastVisit: Date())]
        try await store.save(batch)
        batch.source.targetProfileID = "second"
        try await store.save(batch)

        #expect(await store.batches(profile: "first").isEmpty)
        #expect(await store.batches(profile: "second").count == 1)
        #expect(await store.sources().map(\.targetProfileID) == ["second"])
    }
}

/// The import step's row menu: a row goes into its own new profile unless
/// the person (or an earlier import) picked an existing one.
@MainActor @Suite(.serialized) struct BrowserImportRowTargetTests {
    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private static func profile(_ directory: String) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: .chrome, directoryName: directory, displayName: directory,
                             path: URL(fileURLWithPath: "/tmp/chrome/\(directory)"), availability: [.bookmarks: .available])
    }

    @Test func rowsGoIntoTheProfileTheyPick() async {
        let services = MockOnboardingServices()
        let work = Self.profile("Default"), home = Self.profile("Profile 1"), old = Self.profile("Profile 2")
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [work, home, old])]
        services.targetChoices = [ImportTargetChoice(id: "default", name: "Default"), ImportTargetChoice(id: "p-work", name: "Work")]
        // An earlier import put Profile 2 into Work; one into a profile since deleted starts over.
        services.earlierTargets = [old.id: "p-work", home.id: "gone"]
        let step = OnboardingModel(services: services, step: .importData).importer
        step.detect()
        await Self.until { step.phase == .ready }

        #expect(step.target(work) == nil)
        #expect(step.target(home) == nil)
        #expect(step.target(old) == "p-work")
        step.setTarget("default", for: work)
        step.setTarget("not-a-profile", for: home)
        let targets = Dictionary(uniqueKeysWithValues: step.plan.items.map { ($0.profile.id, $0.target) })
        #expect(targets[work.id] == "default")
        #expect(targets[home.id] == .some(nil))
        #expect(targets[old.id] == "p-work")
    }
}
