import Foundation
import Testing
@testable import CmuxNextBrowser

/// Browser profile records, the cascade and storage cleanup
/// (plans/cmux-next/data-model.md section 5).
@Suite struct BrowserProfileBookTests {
    let work = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    @Test func aNewBookHasOnlyTheDefaultProfile() {
        let book = BrowserProfileBook()
        #expect(book.ordered.map(\.id) == [BrowserProfileRecord.defaultID])
        #expect(book.record(BrowserProfileRecord.defaultID)?.isDefault == true)
    }

    @Test func wireIDsMapOntoEngineProfiles() {
        #expect(BrowserProfileRecord.engineProfile(for: "default") == .default)
        #expect(BrowserProfileRecord.engineProfile(for: work) == BrowserProfileID(rawValue: UUID(uuidString: work)!))
        #expect(BrowserProfileRecord.engineProfile(for: work.uppercased()) == nil)
        #expect(BrowserProfileRecord.engineProfile(for: "prof_1") == nil)
        #expect(BrowserProfileRecord.engineProfile(for: nil) == nil)
        #expect(BrowserProfileRecord.wireID(for: .default) == "default")
        #expect(BrowserProfileRecord.wireID(for: BrowserProfileID(rawValue: UUID(uuidString: work)!)) == work)
        #expect(BrowserProfileRecord.isValidID(BrowserProfileRecord.newID()))
    }

    @Test func editsSurviveAnEncodeDecodeRoundTrip() throws {
        var book = BrowserProfileBook()
        try book.create(id: work, name: "Work", color: "green", icon: "💼")
        try book.rename(work, to: "Client")
        try book.setColor(work, "purple")
        try book.setIcon(work, nil)
        book.workspaceDefaults["s1|w1"] = work
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(BrowserProfileBook.self, from: data)
        #expect(decoded == book)
        let record = try #require(decoded.record(work))
        #expect(record.name == "Client")
        #expect(record.color == "purple")
        #expect(record.icon == nil)
        #expect(decoded.ordered.map(\.id) == ["default", work])
    }

    @Test func creatingAnExistingIDKeepsTheRecord() throws {
        // An interrupted import retries with the same proposed id.
        var book = BrowserProfileBook()
        try book.create(id: work, name: "Chrome · Work", color: nil, icon: nil, source: ["browser": "chrome"])
        let again = try book.create(id: work, name: "Other", color: "red", icon: nil)
        #expect(again.name == "Chrome · Work")
        #expect(book.ordered.count == 2)
        #expect(book.record(work)?.source == ["browser": "chrome"])
    }

    @Test func badInputIsRefused() {
        var book = BrowserProfileBook()
        #expect(throws: BrowserProfileBookError.invalidName) { try book.create(name: "   ", color: nil, icon: nil) }
        #expect(throws: BrowserProfileBookError.invalidID) { try book.create(id: "Work", name: "Work", color: nil, icon: nil) }
        #expect(throws: BrowserProfileBookError.invalidColor) { try book.create(name: "Work", color: "teal", icon: nil) }
        #expect(throws: BrowserProfileBookError.unknownProfile) { try book.rename(work, to: "x") }
        #expect(throws: BrowserProfileBookError.defaultProfile) { try book.delete("default") }
    }

    @Test func deletingRemovesTheRecordAndItsDefaultsAndQueuesItsStorage() throws {
        var book = BrowserProfileBook()
        try book.create(id: work, name: "Work", color: nil, icon: nil)
        book.workspaceDefaults["s1|w1"] = work
        book.workspaceDefaults["s1|w2"] = "default"
        try book.delete(work)
        #expect(book.record(work) == nil)
        #expect(book.workspaceDefaults == ["s1|w2": "default"])
        #expect(book.pendingCleanup == [work])
        // A stray record naming the deleted profile never recreates its store.
        #expect(book.engineProfile(for: work) == .default)
        book.finishCleanup([work])
        #expect(book.pendingCleanup.isEmpty)
    }

    @Test func engineProfileOfAKnownOrUnknownValidIDIsItsUUID() throws {
        // A tab created on another Mac with a profile this Mac has no
        // record for still keeps its own store.
        let book = BrowserProfileBook()
        #expect(book.engineProfile(for: work) == BrowserProfileID(rawValue: UUID(uuidString: work)!))
        #expect(book.engineProfile(for: nil) == .default)
        #expect(book.engineProfile(for: "garbage") == .default)
    }

    @Test func aDaemonRecordsDeletionQueuesThisMacsData() throws {
        // The record lives in the home daemon: no local record, but the
        // engine data and workspace defaults here are this Mac's.
        var book = BrowserProfileBook()
        book.workspaceDefaults["s1|w1"] = work
        book.recordsMigrated = true
        book.markDeleted(work)
        book.markDeleted("default")
        #expect(book.pendingCleanup == [work])
        #expect(book.workspaceDefaults.isEmpty)
        let decoded = try JSONDecoder().decode(BrowserProfileBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.recordsMigrated)
        #expect(decoded == book)
    }

    @Test func positionsFollowCreationAndMove() throws {
        var book = BrowserProfileBook()
        let a = try book.create(name: "A", color: nil, icon: nil)
        let b = try book.create(name: "B", color: nil, icon: nil)
        #expect(book.ordered.map(\.name) == [book.record("default")!.name, "A", "B"])
        try book.move(b.id, to: 1)
        #expect(book.ordered.map(\.id) == ["default", b.id, a.id])
    }
}

@Suite struct BrowserProfileCascadeTests {
    let a = "11111111-1111-4111-8111-111111111111"
    let b = "22222222-2222-4222-8222-222222222222"
    let c = "33333333-3333-4333-8333-333333333333"

    @Test func explicitBeatsWorkspaceBeatsRoomBeatsDefault() {
        let known: (String) -> Bool = { _ in true }
        #expect(BrowserProfileCascade.resolve(explicit: a, workspace: b, room: c, known: known) == a)
        #expect(BrowserProfileCascade.resolve(explicit: nil, workspace: b, room: c, known: known) == b)
        #expect(BrowserProfileCascade.resolve(explicit: nil, workspace: nil, room: c, known: known) == c)
        #expect(BrowserProfileCascade.resolve(explicit: nil, workspace: nil, room: nil, known: known) == "default")
    }

    @Test func unknownLevelsFallThrough() {
        // A workspace default naming a deleted profile does not leak.
        let known: (String) -> Bool = { $0 == c }
        #expect(BrowserProfileCascade.resolve(explicit: nil, workspace: b, room: c, known: known) == c)
        #expect(BrowserProfileCascade.resolve(explicit: nil, workspace: b, room: a, known: known) == "default")
    }

    @Test func tabBadgeShowsOnlyWhenTheTabDiffersFromItsWorkspace() {
        #expect(!BrowserProfileCascade.showsTabBadge(tabProfile: nil, workspaceEffective: "default"))
        #expect(!BrowserProfileCascade.showsTabBadge(tabProfile: "default", workspaceEffective: "default"))
        #expect(BrowserProfileCascade.showsTabBadge(tabProfile: a, workspaceEffective: "default"))
        #expect(BrowserProfileCascade.showsTabBadge(tabProfile: nil, workspaceEffective: a))
        #expect(!BrowserProfileCascade.showsTabBadge(tabProfile: a, workspaceEffective: a))
    }

    @Test func omnibarBadgeShowsOnceThereIsMoreThanOneProfile() {
        #expect(!BrowserProfileCascade.showsOmnibarBadge(profileCount: 1))
        #expect(BrowserProfileCascade.showsOmnibarBadge(profileCount: 2))
    }
}

@Suite struct BrowserProfileStorageCleanupTests {
    @Test func removesOnlyTheDeletedProfilesChromiumDirectoriesAndDerivedStores() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = UUID(), kept = UUID()
        let names = ["Profile-\(gone.uuidString)", "Profile-\(gone.uuidString)-m-0123456789abcdef",
                     "Profile-\(kept.uuidString)", "Profile-\(kept.uuidString)-m-0123456789abcdef", "Default"]
        for name in names {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        let cleanup = BrowserProfileStorageCleanup(chromiumRoot: root)
        let removed = cleanup.removeChromiumData(for: [gone.uuidString.lowercased(), "default", "junk"])
        #expect(removed == [gone.uuidString.lowercased()])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["Default", "Profile-\(kept.uuidString)", "Profile-\(kept.uuidString)-m-0123456789abcdef"])
    }

    @Test func aMissingRootIsNotAnError() {
        let cleanup = BrowserProfileStorageCleanup(chromiumRoot: URL(filePath: "/nonexistent/\(UUID().uuidString)"))
        let id = UUID().uuidString.lowercased()
        #expect(cleanup.removeChromiumData(for: [id]) == [id])
    }
}

@Suite struct BrowserProfileBookFileTests {
    @Test func profilesSurviveARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var book = BrowserProfileBook()
        let work = try book.create(name: "Work", color: "blue", icon: nil)
        try await BrowserProfileBookFile(url: file).save(book)
        let loaded = await BrowserProfileBookFile(url: file).load()
        #expect(loaded == book)
        #expect(loaded.record(work.id)?.name == "Work")
    }

    @Test func aMissingOrCorruptFileLoadsAFreshBook() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await BrowserProfileBookFile(url: file).load() == BrowserProfileBook())
        try Data("{nope".utf8).write(to: file)
        #expect(await BrowserProfileBookFile(url: file).load() == BrowserProfileBook())
    }
}

@Suite struct ChromiumProfilePathTests {
    @Test func aStoreDirectoryNamesItsProfile() {
        let storage = CEFProfileStorage(root: URL(filePath: "/tmp/cmux-root/Chromium"))
        let profile = BrowserProfileID(rawValue: UUID())
        #expect(storage.profile(forPath: storage.cachePath(for: profile).path) == profile)
        #expect(storage.profile(forPath: storage.cachePath(for: profile, machineKey: "0123456789abcdef").path) == profile)
        #expect(storage.profile(forPath: "/tmp/cmux-root/Chromium/Default") == nil)
        #expect(storage.profile(forPath: "/elsewhere/Profile-\(profile.rawValue.uuidString)") == nil)
    }
}
