import Foundation
@testable import CmuxNextUpdater
import Testing

/// Drop back to the previous build: the swap puts the kept build in place and keeps the running
/// one, and a swap that fails part way must leave the kept build in the store (it is the only
/// build the user can drop back to).
@Suite(.serialized) struct RollbackSwapTests {
    private static func makeBundle(at url: URL, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.\(build)"]
        try info.write(to: contents.appending(path: "Info.plist"))
    }

    private static func build(of bundle: URL) -> String? {
        (NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RollbackSwapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func swapPutsTheKeptBuildInPlaceAndKeepsTheRunningOne() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2)
        let target = try #require(store.list().first)

        try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 1)

        #expect(Self.build(of: app) == "100")
        #expect(store.list().map(\.build) == ["200"])
    }

    /// cmux#41013 review F3: a rollback's quit refused at a quit dialog leaves cmux running, so the
    /// running build goes back in place and the kept build back to the store, with its record.
    @Test func aRefusedQuitPutsTheRunningBuildBack() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2, record: KeptRecord(build: "100", date: "2026-11-10", storeSchemas: ["chats": 3]))
        let target = try #require(store.list().first)
        let record = KeptRecord.read(from: target.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName))

        try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 2)
        #expect(Self.build(of: app) == "100")
        try RollbackSwap.undo(current: app, runningBuild: "200", target: target, targetRecord: record, store: store)

        #expect(Self.build(of: app) == "200")
        let kept = store.list(teams: false)
        #expect(kept.map(\.build) == ["100"])
        #expect(kept.first?.storeSchemas == ["chats": 3] && kept.first?.date == "2026-11-10")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(leftovers == ["cmux.app"], "nothing staged is left beside the app")
    }

    @Test func aFailedSwapLeavesTheKeptBuildInTheStore() throws {
        let root = try Self.scratch()
        let versions = root.appending(path: "versions", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versions.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = KeptVersionStore(root: versions, teamID: { _ in "TEAM" })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2)
        let target = try #require(store.list().first)
        // The store's root refuses new folders, so keeping the running build fails mid-swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: versions.path)

        #expect(throws: (any Error).self) {
            try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 1)
        }

        #expect(Self.build(of: app) == "200")
        #expect(Self.build(of: target.bundle) == "100")
        #expect(store.list().map(\.build) == ["100"])
    }

    /// cmux#32624's proof on a fleet Mac: the swap failed with NSCocoaError 512 whose underlying
    /// error was POSIX EINTR. An interrupted call is tried again; any other failure is not.
    @Test func anInterruptedSwapIsTriedAgainAndOtherFailuresAreNot() throws {
        let interrupted = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR)),
            ]),
        ])
        var calls = 0
        try RollbackSwap.retryingInterrupted {
            calls += 1
            if calls < 3 { throw interrupted }
        }
        #expect(calls == 3)

        calls = 0
        #expect(throws: (any Error).self) {
            try RollbackSwap.retryingInterrupted { calls += 1; throw interrupted }
        }
        #expect(calls == 4)

        calls = 0
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(throws: (any Error).self) {
            try RollbackSwap.retryingInterrupted { calls += 1; throw denied }
        }
        #expect(calls == 1)
    }
}
