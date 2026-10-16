import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the "erase all local data" reset: a scratch app
/// container stands in for the real one, a test defaults suite for the app's
/// domain, and a counting stub for the keychain.
@MainActor
@Suite struct MobileLocalDataEraserTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private struct Fixture {
        let home: URL
        let suiteName: String
        let keychainErases = Counter()
        let systemErases = Counter()
        var keychainSucceeds = true

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-erase-\(UUID().uuidString)", isDirectory: true)
            suiteName = "cmux.erase.tests.\(UUID().uuidString)"
            for path in [
                "Documents/probe.json",
                "tmp/cmux-composer-upload-1/photo.jpg",
                "Library/Application Support/cmux-iroh-v2/paired-macs.sqlite3",
                "Library/Caches/artifact-thumbs/a.png",
                "Library/WebKit/WebsiteData/cookies",
                "Library/Preferences/dev.cmux.plist",
                "Library/SplashBoard/Snapshots/launch.ktx",
            ] {
                let url = home.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("x".utf8).write(to: url)
            }
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.set("account", forKey: "cmux.activeAccountID.test")
            defaults.set(false, forKey: "sendAnonymousTelemetry")
        }

        func eraser() -> MobileLocalDataEraser {
            let keychainErases = keychainErases
            let systemErases = systemErases
            let keychainSucceeds = keychainSucceeds
            return MobileLocalDataEraser(
                homeDirectory: home,
                defaultsSuiteName: suiteName,
                defaultsDomain: suiteName,
                eraseKeychain: {
                    keychainErases.increment()
                    return keychainSucceeds
                },
                eraseSystemState: { systemErases.increment() }
            )
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }

        func children(_ path: String) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(
                atPath: home.appendingPathComponent(path).path
            ))
        }

        var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

        func cleanUp() {
            try? FileManager.default.removeItem(at: home)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    @Test func eraseRemovesContainerDataDefaultsAndKeychain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let didErase = await fixture.eraser().erase()

        #expect(didErase)
        #expect(try fixture.children("Documents").isEmpty)
        #expect(try fixture.children("tmp").isEmpty)
        // Only the system-owned entries and the launch-pass marker remain.
        #expect(try fixture.children("Library") == [
            "Preferences", "SplashBoard", MobileLocalDataEraser.pendingMarkerName,
        ])
        #expect(fixture.defaults.string(forKey: "cmux.activeAccountID.test") == nil)
        #expect(fixture.defaults.object(forKey: "sendAnonymousTelemetry") == nil)
        #expect(fixture.keychainErases.count == 1)
        #expect(fixture.systemErases.count == 1)
    }

    @Test func launchPassErasesStateRewrittenAfterTheInProcessErase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.eraser().erase()

        // Live objects keep writing after the in-process erase.
        let rewritten = fixture.home.appendingPathComponent("Library/Application Support/cmux-app.log")
        try FileManager.default.createDirectory(
            at: rewritten.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("late".utf8).write(to: rewritten)
        fixture.defaults.set(1, forKey: "dev.cmux.analytics.sessionCount")

        let relaunched = fixture.eraser()
        #expect(relaunched.hasPendingErase)
        #expect(relaunched.completePendingEraseIfNeeded())

        #expect(!fixture.exists("Library/Application Support"))
        #expect(fixture.defaults.object(forKey: "dev.cmux.analytics.sessionCount") == nil)
        #expect(!relaunched.hasPendingErase)
        #expect(fixture.keychainErases.count == 2)
        // The launch pass runs before UIKit and WebKit exist.
        #expect(fixture.systemErases.count == 1)
    }

    @Test func launchPassDoesNothingWithoutAPendingErase() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        #expect(!fixture.eraser().completePendingEraseIfNeeded())

        #expect(fixture.exists("Documents/probe.json"))
        #expect(fixture.defaults.string(forKey: "cmux.activeAccountID.test") == "account")
        #expect(fixture.keychainErases.count == 0)
    }

    @Test func failedInProcessEraseStillLeavesTheMarker() async throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.keychainSucceeds = false

        let didErase = await fixture.eraser().erase()

        // Written before erasing starts, so a partial or killed erase is
        // always finished by the next launch.
        #expect(!didErase)
        #expect(fixture.eraser().hasPendingErase)
        #expect(!fixture.exists("Documents/probe.json"))
    }

    @Test func failedLaunchPassKeepsTheMarkerForTheNextLaunch() async throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.eraser().erase()

        fixture.keychainSucceeds = false
        #expect(!fixture.eraser().completePendingEraseIfNeeded())
        #expect(fixture.eraser().hasPendingErase)

        fixture.keychainSucceeds = true
        #expect(fixture.eraser().completePendingEraseIfNeeded())
        #expect(!fixture.eraser().hasPendingErase)
    }
}
