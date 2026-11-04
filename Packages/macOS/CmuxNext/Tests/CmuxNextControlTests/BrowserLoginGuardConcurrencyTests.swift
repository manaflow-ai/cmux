@testable import CmuxNextControl
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct BrowserLoginGuardConcurrencyTests {
    @Test func unsavedScriptAndRawAdmissionsCannotExecutePersistentCode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let guards = BrowserLoginGuards(file: blocker.appendingPathComponent("guards.json"))
        #expect(await !guards.beginScript(profile: "web", origins: ["https://a.test"]))
        #expect(await !guards.beginScript(profile: "opaque", origins: ["null"]))
        #expect(await !guards.beginRawDevTools(tab: "raw", profile: "raw", origins: ["https://a.test"]))
    }

    @Test func rawDevToolsReservesEveryTargetInItsProfileAfterDetachAndRestart() async throws {
        let file = BrowserPageFillLoginTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guards = BrowserLoginGuards(file: file)
        #expect(await guards.beginRawDevTools(tab: "raw", profile: "raw", origins: ["https://a.test"]))
        guards.rawDevToolsEnded(tab: "raw")
        #expect(await guards.beginFill(tab: "other", profile: "raw", origins: ["https://child.test"]).admission == .scripted)
        let restored = BrowserLoginGuards(file: file)
        #expect(await restored.beginFill(tab: "other", profile: "raw", origins: ["https://child.test"]).admission == .scripted)
        #expect(await restored.beginFill(tab: "other", profile: "other", origins: ["https://child.test"]).admission == .admitted)
    }

    /// A fill that wrote nothing (`no_login_field`, `navigated`) still sent its script, with the
    /// username and password as literals, to the tab's renderer. Page-world agent code on the site
    /// is released again (it cannot read the isolated world), but raw DevTools (Debugger, heap
    /// snapshots) could read the script source while V8 keeps it, so the profile refuses a raw
    /// relay for good, across a restart.
    @Test func aFillThatWroteNothingStillRefusesRawDevToolsInItsProfileAfterRestart() async throws {
        let file = BrowserPageFillLoginTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guards = BrowserLoginGuards(file: file)
        let fill = await guards.beginFill(tab: "tab", profile: "agent", origins: ["https://a.test"])
        #expect(fill.admission == .admitted)
        await guards.forgetFill(fill)
        #expect(await guards.beginScript(profile: "agent", origins: ["https://a.test"]), "page-world code is released")
        #expect(await !guards.beginRawDevTools(tab: "tab", profile: "agent", origins: ["https://b.test"]))
        #expect(!guards.rawMessageAllowed(profile: "agent"))
        let restored = BrowserLoginGuards(file: file)
        await restored.prepare()
        #expect(await !restored.beginRawDevTools(tab: "other", profile: "agent", origins: ["https://b.test"]))
        #expect(!restored.rawMessageAllowed(profile: "agent"))
        // Another profile never held the credentials: its relay runs.
        #expect(await restored.beginRawDevTools(tab: "person", profile: "other", origins: ["https://b.test"]))
    }

    @Test func opaqueCodeAndFillsExcludeEachOtherAcrossAProfileAndRestart() async throws {
        let file = BrowserPageFillLoginTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guards = BrowserLoginGuards(file: file)
        #expect(await guards.beginScript(profile: "opaque", origins: ["null"]))
        #expect(await guards.beginFill(tab: "tab", profile: "opaque", origins: ["https://a.test"]).admission == .scripted)
        let restored = BrowserLoginGuards(file: file)
        #expect(await restored.beginFill(tab: "tab", profile: "opaque", origins: ["https://b.test"]).admission == .scripted)
        #expect(await restored.beginFill(tab: "tab", profile: "filled", origins: ["https://a.test"]).admission == .admitted)
        #expect(await !restored.beginScript(profile: "filled", origins: ["null"]))
    }

    @Test func aFailedFillCannotUnprotectAnotherTabsSuccessfulFill() async throws {
        let (entered, signalEntered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (release, signalRelease) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signalRelease.yield(); signalRelease.finish(); signalEntered.finish() }
        let suite = BrowserPageFillLoginTests()
        let file = BrowserPageFillLoginTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guards = BrowserLoginGuards(file: file)
        let engine = BrowserPageFillLoginTests.LoginEngine(url: "https://www.example.com/login", fill: [:]) { tab in
            if tab == "tab_0123abcd" {
                signalEntered.yield()
                _ = await release.first { _ in true }
                return ["value": ["username": false, "password": false, "reason": "no_login_field"]]
            }
            return BrowserPageFillLoginTests.filledBoth
        }
        let router = suite.install(engine, BrowserPageFillLoginTests.Lookups(BrowserPageFillLoginTests.saved), guards: guards)
        let first = Task { await suite.call(router) }
        _ = await entered.first { _ in true }
        let second = try await suite.call(router, tab: "tab_other").get()
        #expect(second["password_filled"] == true)
        signalRelease.yield()
        #expect(try await first.value.get()["filled"] == false)
        guard case .failure(let refusal) = await suite.eval(router, tab: "tab_other") else {
            Issue.record("a failed fill released the successful fill's agent-code guard")
            return
        }
        #expect(refusal.code == "login_filled")
        #expect(await !guards.mayCapture(profile: nil, origins: ["https://www.example.com"]))
        #expect(!guards.rawMessageAllowed(profile: nil))
        let restored = BrowserLoginGuards(file: file)
        #expect(await !restored.beginScript(profile: nil, origins: ["https://www.example.com"]))
    }
}
