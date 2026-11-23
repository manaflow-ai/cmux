import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Settings > Extensions reaches the daemon's `apps.settings.*` only from the Settings page, and a
/// change only on the person's own click or key: with no connection behind the route, an allowed
/// call reaches the "closed" answer, past those checks.
@Suite
@MainActor
struct ExtensionSettingsPageRouteTests {
    private let route = ExtensionSettingsPageRoute { nil }
    private let change: CmuxNextSettings.JSONValue = .object([
        "app": .string("cmux/prefs"), "values": .object(["compact": .bool(true)]), "idempotency_key": .string("k1"),
    ])

    private func code(_ op: String, _ params: CmuxNextSettings.JSONValue = .object([:]), page: String = PageDescriptor.settings.id,
                      gesture: Bool = false) async -> String? {
        do {
            _ = try await route.call(ExtensionSettingsPageRoute.prefix + op, params: params,
                                     context: PageCallContext(page: page, userGesture: gesture))
            return nil
        } catch let error as PageError {
            return error.code
        } catch {
            return "\(error)"
        }
    }

    @Test func listingReachesTheDaemon() async {
        #expect(await code("list") == PageError.closed.code)
    }

    @Test func aChangeNeedsThePersonsGesture() async {
        #expect(await code("set", change) == "cmux.settings.user_only")
        #expect(await code("set", change, gesture: true) == PageError.closed.code)
    }

    @Test func aChangeNeedsAnAppAndAnObjectOfValues() async {
        let notAnObject: CmuxNextSettings.JSONValue = .object(["app": .string("cmux/prefs"), "values": .string("x")])
        #expect(await code("set", notAnObject, gesture: true) == PageError.invalidParams("").code)
    }

    @Test func onlyTheSettingsPageAndItsOwnOpsAreServed() async {
        #expect(await code("list", page: PageDescriptor.apps.id) == PageError.unknownOp("").code)
        #expect(await code("remove", gesture: true) == PageError.unknownOp("").code)
    }
}
