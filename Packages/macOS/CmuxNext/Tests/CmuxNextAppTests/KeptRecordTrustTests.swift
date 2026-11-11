import CryptoKit
import Foundation
@testable import CmuxNextUpdater
import Testing

/// What a kept build's record may vouch for (cmux#41013 review follow-ups). The record is a file
/// beside the bundle, so a process that changes the bundle can take its seal again and write a new
/// record: only a record signed with the app's Keychain key (``KeptRecordKey``) spares the full
/// check. The seal is taken again right before the swap moves the bundle into place. A build whose
/// check or first run fails is not tried again at every launch, only once another build runs.
@Suite(.serialized) struct KeptRecordTrustTests {
    private nonisolated static let key = SymmetricKey(size: .bits256)

    private nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "KeptRecordTrustTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeBundle(at url: URL, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)"]
        try info.write(to: contents.appending(path: "Info.plist"))
        try Data("ok()".utf8).write(to: contents.appending(path: "Resources/app.js"))
    }

    private static func store(_ root: URL, full: Counter, team: String? = "TEAM", key: SymmetricKey? = Self.key) -> KeptVersionStore {
        KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in full.add(); return team },
                         quickTeamID: { _ in team }, recordKey: { key })
    }

    @Test func aRecordWrittenForAChangedBundleIsNotTrusted() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = Counter()
        let store = Self.store(root, full: full)
        let app = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "100")
        try store.keep(bundle: app, build: "100", limit: 2)
        let kept = try #require(store.list(teams: false).first)
        _ = store.checkedTeam(of: kept)
        #expect(full.value == 1, "a signed record spares the full check")

        // Change a script, then write the record the change would need: its seal taken again.
        try Data("evil()".utf8).write(to: kept.bundle.appending(path: "Contents/Resources/app.js"))
        let file = kept.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName)
        var forged = try #require(KeptRecord.read(from: file))
        forged.seal = KeptSeal(bundle: kept.bundle)
        try forged.save(to: file)
        _ = store.checkedTeam(of: kept)
        #expect(full.value == 2, "a record whose MAC does not cover its seal is checked in full")

        // No Keychain key (an ad hoc build): no record is trusted.
        let keyless = Self.store(root, full: full, key: nil)
        _ = keyless.checkedTeam(of: kept)
        #expect(full.value == 3)
    }

    @Test func theSwapRefusesABundleChangedAfterTheCheck() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Self.store(root, full: Counter())
        let old = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: old, build: "100")
        try store.keep(bundle: old, build: "100", limit: 2)
        let target = try #require(store.list(teams: false).first)
        #expect(store.checkedTeam(of: target) == "TEAM")
        try Data("evil()".utf8).write(to: target.bundle.appending(path: "Contents/Resources/app.js"))
        let current = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: current, build: "200")

        #expect(throws: RollbackSwap.Changed.self) {
            try RollbackSwap.perform(current: current, currentBuild: "200", target: target, store: store, limit: 2)
        }
        #expect(FileManager.default.fileExists(atPath: target.bundle.path), "nothing moved")
        #expect(NSDictionary(contentsOf: current.appending(path: "Contents/Info.plist"))?["CFBundleVersion"] as? String == "200")
    }

    @Test func aBuildThatFailsItsCheckIsTriedAgainOnlyWhenAnotherBuildRuns() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = Counter()
        let store = Self.store(root, full: full, team: nil)
        let app = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "100")
        try store.keep(bundle: app, build: "100", limit: 2, check: .later)

        #expect(store.sealPending(runningBuild: "200").isEmpty)
        #expect(store.sealPending(runningBuild: "200").isEmpty)
        #expect(full.value == 1, "not again at the next launch of the same build")
        #expect(store.sealPending(runningBuild: "201").isEmpty)
        #expect(full.value == 2, "a new build tries once")
    }
}
