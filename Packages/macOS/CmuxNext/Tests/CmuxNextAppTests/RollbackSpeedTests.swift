@testable import CmuxNextUpdater
import CmuxUpdater
import CryptoKit
import Foundation
import os
import Testing

/// Going back to a previous nightly is one click that must not take seconds before it starts
/// (Leo, 2026-11-11: "reverting the app to previous nightly is really slow/doesn't work very well
/// sometimes?/needs less shitty ui"). A full signature check of a bundle reads every nested
/// binary, so listing the kept builds never runs one, only the rollback's target is checked (the
/// card's repeated reads reuse the answer while the bundle stays the same), and a kept build's schemas are read from the store instead of a cold
/// start of its CLI. The Channels card reads each step of a Switch off ``BuildSwitchProgress``.
@Suite(.serialized) struct RollbackSpeedTests {
    /// Counts the signature checks a store makes.
    private nonisolated final class Checks: Sendable {
        let count = OSAllocatedUnfairLock(initialState: 0)
        func team(_ bundle: URL) -> String? {
            count.withLock { $0 += 1 }
            return "TEAM"
        }
    }

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RollbackSpeedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A bundle with an Info.plist and the code seal the signature cache keys on.
    private static func makeBundle(at url: URL, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.\(build)"]
        try info.write(to: contents.appending(path: "Info.plist"))
        try Data("seal \(build)".utf8).write(to: contents.appending(path: "_CodeSignature/CodeResources"))
    }

    private static func store(keeping builds: [String], in root: URL, checks: Checks) throws -> KeptVersionStore {
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { checks.team($0) })
        for build in builds {
            let source = root.appending(path: "source-\(build)/cmux.app", directoryHint: .isDirectory)
            try makeBundle(at: source, build: build)
            try store.keep(bundle: source, build: build, limit: builds.count)
        }
        return store
    }

    @Test func listingAndPruningTheKeptBuildsChecksNoSignature() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let checks = Checks()
        let store = try Self.store(keeping: ["100", "200", "300"], in: root, checks: checks)

        let kept = store.list()

        #expect(kept.map(\.build) == ["300", "200", "100"])
        #expect(kept.allSatisfy { $0.teamID == nil })
        #expect(checks.count.withLock { $0 } == 0)
    }

    @Test func theCardsReadsReuseTheTargetsCheckAndTheClickChecksAfresh() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let checks = Checks()
        let store = try Self.store(keeping: ["100", "200"], in: root, checks: checks)
        let target = try #require(store.list().first)

        // Each open of the Channels card asks whether Go Back would run.
        #expect(store.verified(target, reusing: true).teamID == "TEAM")
        #expect(store.verified(target, reusing: true).teamID == "TEAM")
        #expect(checks.count.withLock { $0 } == 1)
        // The click that runs the rollback checks the bundle it is about to put in place.
        #expect(store.verified(target).teamID == "TEAM")
        #expect(checks.count.withLock { $0 } == 2)

        // A new copy at the same path is a new seal file: even the card checks it again.
        let source = root.appending(path: "again/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: source, build: "200")
        try store.keep(bundle: source, build: "200", limit: 2)
        _ = store.verified(try #require(store.list().first), reusing: true)
        #expect(checks.count.withLock { $0 } == 3)
    }

    @Test func aFailedCheckIsNotRemembered() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in
            failures.withLock { $0 += 1 }
            return nil
        })
        let source = root.appending(path: "source/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: source, build: "100")
        try store.keep(bundle: source, build: "100", limit: 1)
        let target = try #require(store.list().first)

        #expect(store.verified(target, reusing: true).teamID == nil)
        #expect(store.verified(target, reusing: true).teamID == nil)
        #expect(failures.withLock { $0 } == 2)
    }

    @Test func recordedSchemasAreReadBackAndOutliveAReKeepOfTheSameBuild() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Self.store(keeping: ["100"], in: root, checks: Checks())
        #expect(store.list().first?.storeSchemas == nil)

        store.recordSchemas(["workspace_registry": 3, "conversation_store": 7], for: "100")
        #expect(store.list().first?.storeSchemas == ["workspace_registry": 3, "conversation_store": 7])

        // The rollback swap keeps the running build again under its number: the record stays.
        let source = root.appending(path: "again/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: source, build: "100")
        try store.keep(bundle: source, build: "100", limit: 1)
        #expect(store.list().first?.storeSchemas == ["workspace_registry": 3, "conversation_store": 7])
        // The record is not taken for a bundle.
        #expect(store.list().map(\.bundle.lastPathComponent) == ["cmux.app"])
    }

    @Test func aRecordForAnotherBundleOrInTheOldFormIsNeverRead() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Self.store(keeping: ["100"], in: root, checks: Checks())
        store.recordSchemas(["workspace_registry": 3], for: "100")

        // Another bundle kept under the same number (a different seal): the record names the old one.
        let other = root.appending(path: "other/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: other, build: "100")
        try Data("another seal".utf8).write(to: other.appending(path: "Contents/_CodeSignature/CodeResources"))
        try store.keep(bundle: other, build: "100", limit: 1)
        #expect(store.list().first?.storeSchemas == nil)

        // A bare schemas object (no seal) claims nothing.
        try Data(#"{"workspace_registry": 99}"#.utf8).write(to: store.root.appending(path: "100/store-schemas.json"))
        #expect(store.list().first?.storeSchemas == nil)
    }

    @Test func aRecordForABuildNotKeptIsNotWritten() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Self.store(keeping: ["100"], in: root, checks: Checks())
        store.recordSchemas(["workspace_registry": 3], for: "999")
        #expect(!FileManager.default.fileExists(atPath: store.root.appending(path: "999").path))
    }

    // MARK: Switch progress

    @Test func eachStepReadsWhatIsHappeningAndKeepsItsOrder() {
        #expect(BuildSwitchProgress(build: "1", stage: .download, fraction: 0.426).label == "Downloading… 42%")
        #expect(BuildSwitchProgress(build: "1", stage: .download).label == "Downloading…")
        #expect(BuildSwitchProgress(build: "1", stage: .verify).label == "Checking the download…")
        #expect(BuildSwitchProgress(build: "1", stage: .stores).label == "Checking it can open your sessions…")
        #expect(BuildSwitchProgress(build: "1", stage: .restart).label == "Restarting…")
        #expect(BuildSwitchProgress.Stage.allCases.map(\.order) == [0, 1, 2, 3])
        let page = BuildSwitchProgress(build: "7", stage: .download, fraction: 1.5).page
        #expect(page["build"] as? String == "7")
        #expect(page["fraction"] as? Double == 1)
        #expect(BuildSwitchProgress(build: "7", stage: .verify).page["fraction"] is NSNull)
    }

    private static let key = Curve25519.Signing.PrivateKey()
    private nonisolated static let image = Data("cmux NEXT disk image".utf8)

    /// A download that reports many fractions, a disk image that is a folder.
    private struct Volume: AppChannelDownloading, DiskImageMounting {
        let folder: URL
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
            for step in 0...400 { progress(Double(step) / 400) }
            try RollbackSpeedTests.image.write(to: destination)
        }
        func attach(_ image: URL) async throws -> URL { folder }
        func detach(_ mountPoint: URL) async {}
    }

    private struct Inspector: AppSignatureInspecting {
        func inspect(appURL: URL, teamIdentifier: String) throws -> AppSignatureReport {
            let id = Bundle(url: appURL)?.bundleIdentifier
            return AppSignatureReport(bundleIdentifier: id, signingIdentifier: id, teamIdentifier: "TEAM",
                                      satisfiesDeveloperIDRequirement: true)
        }
    }

    @Test func aDownloadReportsEachWholePercentThenTheCheck() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = "com.cmuxterm.app.nightly.cmux-next"
        let contents = root.appending(path: "volume/cmux NEXT.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleVersion": "500", "CFBundleShortVersionString": "1.0.500"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        let steps = OSAllocatedUnfairLock(initialState: [BuildSwitchProgress]())
        let volume = Volume(folder: root.appending(path: "volume", directoryHint: .isDirectory))
        let download = BuildSwitchDownload(store: KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" }),
                                           bundleIdentifier: bundleID, teamID: "TEAM",
                                           publicEDKey: Self.key.publicKey.rawRepresentation.base64EncodedString(),
                                           downloader: volume, mounter: volume, inspector: Inspector(), temporaryDirectory: root,
                                           progress: { step in steps.withLock { $0.append(step) } })
        let signature = ArchiveSignature(edSignature: try Self.key.signature(for: Self.image).base64EncodedString(), length: Self.image.count)

        let failure = await download.keep(build: "500", from: URL(string: "https://files-next.cmux.com/nightly-next/x.dmg")!, signature: signature)

        #expect(failure == nil)
        let seen = steps.withLock { $0 }
        #expect(seen.filter { $0.stage == .download }.count == 101)
        #expect(seen.last?.stage == .verify)
        #expect(seen.allSatisfy { $0.build == "500" })
    }
}
