import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// cx-d0d.41, remote-localhost.md section 9: deleting a browser profile
/// deletes its remote-localhost derived stores (`Profile-<UUID>-m-<machine>`,
/// one per machine) with its own Chromium store, and no other profile's.
/// Runs Delete Browser Profile through the app's action registry, as the
/// palette and `cmux browser-profile delete` reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DeleteProfileDerivedStoresTests {
    @Test func deletingAProfileRemovesItsDerivedStores() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let book = FileManager.default.temporaryDirectory.appending(path: "cn-dstores-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: book) }
        services.browserProfiles.load(directory: book)
        try await Self.until { services.browserProfiles.isLoaded }
        let name = "Derived Stores \(UUID().uuidString.prefix(8))"
        try services.browserProfiles.createProfileNow(name: name, color: nil, icon: nil)
        let record = try #require(services.browserProfiles.ordered.first { $0.name == name })

        // The profile's store, two machines' derived stores, and another profile's derived store.
        let root = services.cache.cef.storageRoot
        let base = "Profile-" + record.engineProfile.rawValue.uuidString
        let own = [base, base + "-m-0123456789abcdef", base + "-m-fedcba9876543210"].map { root.appending(path: $0) }
        let other = root.appending(path: "Profile-\(UUID().uuidString)-m-0123456789abcdef")
        // Only this test's fresh UUIDs, also when it fails (the root can be cmux NEXT's own).
        defer { for directory in own + [other] { try? FileManager.default.removeItem(at: directory) } }
        for directory in own + [other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appending(path: "Cookies"))
        }

        let target = ActionTargetRef(kind: .browserProfile, id: record.id)
        #expect(services.registry.perform("browserProfile.delete", invocation: ActionInvocation(target: target).confirmed()))
        try await Self.until { own.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
        #expect(FileManager.default.fileExists(atPath: other.path), "deleting a profile removed another profile's derived store")
        // The cleanup's last write (the book) lands before the temp book is removed.
        try await Self.until { services.browserProfiles.book.pendingCleanup.isEmpty }
    }

    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out")
    }
}
