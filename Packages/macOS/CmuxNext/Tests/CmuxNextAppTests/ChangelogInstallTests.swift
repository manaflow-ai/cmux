@testable import CmuxNextUpdater
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// What's New's Install (Leo 2026-11-05: "Like literally with a click to a past nightly"): the list
/// (`installable`) says whether this app can restart into another build, and `install {build}` runs the updater's
/// switch only from the person's own click on the What's New page, answering a refusal as an error.
@MainActor @Suite struct ChangelogInstallTests {
    static let gesture = PageCallContext(page: "cmux.changelog", userGesture: true, gestureEvent: 100)

    @MainActor final class Rig {
        var asked: [String] = []
        var refusal: String?
        lazy var page = ChangelogInstallProvider(install: { [unowned self] build in asked.append(build); return refusal })

        func install(_ params: JSONValue, _ context: PageCallContext = ChangelogInstallTests.gesture) async throws -> JSONValue {
            try await page.call("cmux.changelog.install", params: params, context: context)
        }
    }

    private static func code(_ run: () async throws -> JSONValue) async -> String? {
        do { _ = try await run(); return nil } catch let error as PageError { return error.code } catch { return "\(error)" }
    }

    @Test func theListSaysWhetherThisAppInstalls() async throws {
        let rig = Rig()
        #expect(try await rig.page.call("cmux.changelog.installable", params: [:], context: Self.gesture)["installs"] == .bool(true))
        let none = ChangelogInstallProvider(install: nil)
        #expect(try await none.call("cmux.changelog.installable", params: [:], context: Self.gesture)["installs"] == .bool(false))
        #expect(await Self.code { try await none.call("cmux.changelog.install", params: ["build": .string("41")], context: Self.gesture) }
            == "cmux.protocol.unknown_op")
    }

    @Test func installRunsOnlyOnThePersonsClickOnWhatsNew() async throws {
        let rig = Rig()
        #expect(await Self.code { try await rig.install(["build": .string("41")], PageCallContext(page: "cmux.changelog")) }
            == "cmux.changelog.user_only")
        #expect(await Self.code { try await rig.install(["build": .string("41")], PageCallContext(page: "cmux.settings", userGesture: true)) }
            == "cmux.changelog.user_only")
        #expect(await Self.code { try await rig.install([:]) } != nil)
        #expect(rig.asked.isEmpty)
        #expect(try await rig.install(["build": .string("41")]) == .object([:]))
        #expect(rig.asked == ["41"])
    }

    @Test func aRefusalReachesThePage() async throws {
        let rig = Rig()
        rig.refusal = "That build was pulled from the feed. Pick another one."
        do {
            _ = try await rig.install(["build": .string("41")])
            Issue.record("a refused install answered success")
        } catch let error as PageError {
            #expect(error.code == "cmux.page.refused")
            #expect(error.message == rig.refusal)
        }
    }

    @Test func offTheSettingListsNoInstallAndRunsNone() async throws {
        var on = false
        var asked: [String] = []
        let page = ChangelogInstallProvider(install: { build in asked.append(build); return nil }, enabled: { on })
        #expect(try await page.call("cmux.changelog.installable", params: [:], context: Self.gesture)["installs"] == .bool(false))
        #expect(await Self.code { try await page.call("cmux.changelog.install", params: ["build": .string("41")], context: Self.gesture) }
            == "cmux.protocol.unknown_op")
        #expect(asked.isEmpty)
        on = true
        #expect(try await page.call("cmux.changelog.installable", params: [:], context: Self.gesture)["installs"] == .bool(true))
    }
}
