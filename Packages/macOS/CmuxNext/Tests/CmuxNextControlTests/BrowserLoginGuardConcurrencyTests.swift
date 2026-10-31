@testable import CmuxNextControl
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct BrowserLoginGuardConcurrencyTests {
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
