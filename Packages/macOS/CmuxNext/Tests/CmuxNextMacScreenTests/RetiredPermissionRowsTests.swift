@testable import CmuxNextMacScreen
import CmuxNextCompat
import Foundation
import Testing

/// The launch removes the Privacy & Security rows of the helpers cmux NEXT retired (cmux Remote,
/// the legacy Computer Use helper) once per app version, never the app's own id, never a classic
/// id while classic cmux is on the Mac, and never a holder this build still embeds.
@Suite struct RetiredPermissionRowsTests {
    /// What the fake Mac saw: each `tccutil reset` it was asked for.
    private nonisolated final class Calls: Sendable {
        let resets = Mutex<[String]>([])
    }

    private static func mac(version: String? = "1.0(100)", embedded: Set<String> = [],
                            classic: Bool = false, failing: Set<String> = [], calls: Calls) -> RetiredPermissionRows.Mac {
        RetiredPermissionRows.Mac(
            version: { version },
            embeds: { embedded.contains($0) },
            classicPresent: { classic },
            reset: { service, id in
                calls.resets.withLock { $0.append("\(service) \(id)") }
                return failing.contains(id) ? "exit 1: No such bundle identifier" : nil
            })
    }

    private static func withSuite(_ body: (String, UserDefaults) async throws -> Void) async throws {
        let name = "cmux.tests.RetiredPermissionRows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(name, defaults)
    }

    private static func all(_ ids: [String]) -> [String] {
        ids.flatMap { id in RetiredPermissionRows.services.map { "\($0) \(id)" } }
    }

    @Test func theRetiredIdsAreTheRemoteAndLegacyComputerUseHelpersOnly() {
        let ids = RetiredPermissionRows.holders.map(\.bundleID)
        #expect(ids == ["com.cmuxterm.remote", "com.cmuxterm.remote.dev", "com.cmuxterm.cua", "com.cmuxterm.cua.dev"])
        #expect(RetiredPermissionRows.services == ["ScreenCapture", "Accessibility", "ListenEvent", "PostEvent"])
        for id in ids {
            #expect(!id.hasPrefix("com.cmuxterm.app"), "never an app's own id, classic or NEXT")
            #expect(!id.hasSuffix(".screen-sharing"), "never the Screen Sharing helper")
        }
        #expect(RetiredPermissionRows.holders.filter(\.sharedWithClassic).map(\.bundleID) == ["com.cmuxterm.cua", "com.cmuxterm.cua.dev"])
    }

    @Test func resetsEveryServiceOfEveryHolderWithNoClassicThenNotAgainThisVersion() async throws {
        try await Self.withSuite { name, defaults in
            let calls = Calls()
            let rows = RetiredPermissionRows(suiteName: name, mac: Self.mac(calls: calls))
            let report = try #require(await rows.cleanUpInBackground().value)
            let expected = Self.all(RetiredPermissionRows.holders.map(\.bundleID))
            #expect(report.reset == expected)
            #expect(report.failed.isEmpty && report.kept.isEmpty)
            #expect(calls.resets.withLock { $0 } == expected)
            #expect(defaults.string(forKey: RetiredPermissionRows.doneKey) == "1.0(100)")
            #expect(await rows.cleanUpInBackground().value == nil)
            #expect(calls.resets.withLock { $0 }.count == expected.count, "a second launch of this version runs nothing")
        }
    }

    @Test func aNewVersionRunsAgain() async throws {
        try await Self.withSuite { name, defaults in
            defaults.set("1.0(99)", forKey: RetiredPermissionRows.doneKey)
            let calls = Calls()
            #expect(await RetiredPermissionRows(suiteName: name, mac: Self.mac(calls: calls)).cleanUpInBackground().value != nil)
            #expect(defaults.string(forKey: RetiredPermissionRows.doneKey) == "1.0(100)")
        }
    }

    @Test func classicOnTheMacKeepsTheClassicSharedHelper() async throws {
        try await Self.withSuite { name, _ in
            let calls = Calls()
            let report = try #require(await RetiredPermissionRows(suiteName: name, mac: Self.mac(classic: true, calls: calls)).cleanUpInBackground().value)
            #expect(report.kept == ["com.cmuxterm.cua": .classic, "com.cmuxterm.cua.dev": .classic])
            #expect(calls.resets.withLock { $0 } == Self.all(["com.cmuxterm.remote", "com.cmuxterm.remote.dev"]))
            #expect(!calls.resets.withLock { $0 }.contains { $0.contains("cua") })
        }
    }

    @Test func aBuildThatStillEmbedsCmuxRemoteKeepsBothRemoteIds() async throws {
        try await Self.withSuite { name, _ in
            let calls = Calls()
            let mac = Self.mac(embedded: ["cmux Remote (dev).app"], calls: calls)
            let report = try #require(await RetiredPermissionRows(suiteName: name, mac: mac).cleanUpInBackground().value)
            #expect(report.kept == ["com.cmuxterm.remote": .embedded, "com.cmuxterm.remote.dev": .embedded])
            #expect(calls.resets.withLock { $0 } == Self.all(["com.cmuxterm.cua", "com.cmuxterm.cua.dev"]))
        }
    }

    @Test func aFailedResetIsReportedAndTheVersionStillMarked() async throws {
        try await Self.withSuite { name, defaults in
            let calls = Calls()
            let mac = Self.mac(failing: ["com.cmuxterm.cua"], calls: calls)
            let report = try #require(await RetiredPermissionRows(suiteName: name, mac: mac).cleanUpInBackground().value)
            #expect(report.failed.count == RetiredPermissionRows.services.count)
            #expect(report.failed.allSatisfy { $0.contains("com.cmuxterm.cua: exit 1") })
            #expect(defaults.string(forKey: RetiredPermissionRows.doneKey) == "1.0(100)")
        }
    }

    @Test func noBundleVersionRunsNothing() async throws {
        try await Self.withSuite { name, defaults in
            let calls = Calls()
            #expect(await RetiredPermissionRows(suiteName: name, mac: Self.mac(version: nil, calls: calls)).cleanUpInBackground().value == nil)
            #expect(calls.resets.withLock { $0 }.isEmpty)
            #expect(defaults.object(forKey: RetiredPermissionRows.doneKey) == nil)
        }
    }
}
