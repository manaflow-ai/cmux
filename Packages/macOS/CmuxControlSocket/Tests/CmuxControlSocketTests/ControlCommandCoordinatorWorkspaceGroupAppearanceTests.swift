import CmuxSettings
import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("Control command workspace-group color and icon")
struct ControlCommandCoordinatorWorkspaceGroupAppearanceTests {
    private let groupID = UUID()

    @Test func setColorAcceptsHex() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("workspace.group.set_color", ["hex": .string(" #1565C0 ")]))

        #expect(context.colorCalls == ["#1565C0"])
        #expect(payload(result)?["custom_color"] == .string("#1565C0"))
    }

    @Test func setColorAcceptsConfigSpellingColor() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("workspace.group.set_color", ["color": .string("#1565C0")]))

        #expect(context.colorCalls == ["#1565C0"])
        #expect(payload(result)?["custom_color"] == .string("#1565C0"))
    }

    @Test func setColorAcceptsMatchingAliases() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request(
            "workspace.group.set_color",
            ["hex": .string("#1565C0"), "color": .string(" #1565C0")]
        ))

        #expect(context.colorCalls == ["#1565C0"])
    }

    @Test func setColorRejectsConflictingAliasesWithoutMutating() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(
            "workspace.group.set_color",
            ["hex": .string("#1565C0"), "color": .string("#6A1B9A")]
        ))

        #expect(errorCode(result) == "invalid_params")
        #expect(context.colorCalls.isEmpty)
    }

    @Test func setColorWithoutValueStillClears() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("workspace.group.set_color", ["hex": .null]))

        #expect(context.colorCalls == [nil])
        #expect(payload(result)?["custom_color"] == .null)
    }

    @Test func setIconAcceptsSymbol() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("workspace.group.set_icon", ["symbol": .string("person.fill")]))

        #expect(context.iconCalls == ["person.fill"])
        #expect(payload(result)?["icon_symbol"] == .string("person.fill"))
    }

    @Test func setIconAcceptsConfigSpellingIcon() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("workspace.group.set_icon", ["icon": .string("person.fill")]))

        #expect(context.iconCalls == ["person.fill"])
        #expect(payload(result)?["icon_symbol"] == .string("person.fill"))
    }

    @Test func setIconRejectsConflictingAliasesWithoutMutating() {
        let context = FakeWorkspaceGroupAppearanceContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(
            "workspace.group.set_icon",
            ["symbol": .string("person.fill"), "icon": .string("briefcase.fill")]
        ))

        #expect(errorCode(result) == "invalid_params")
        #expect(context.iconCalls.isEmpty)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue]
    ) -> ControlRequest {
        var params = params
        params["group_id"] = .string(groupID.uuidString)
        return ControlRequest(id: .int(1), method: method, params: params)
    }

    private func payload(_ result: ControlCallResult) -> [String: JSONValue]? {
        guard case .ok(.object(let payload)) = result else { return nil }
        return payload
    }

    private func errorCode(_ result: ControlCallResult) -> String? {
        guard case .err(let code, _, _) = result else { return nil }
        return code
    }
}

@MainActor
final class FakeWorkspaceGroupAppearanceContext: ControlCommandContext {
    var colorCalls: [String?] = []
    var iconCalls: [String?] = []

    func controlSetWorkspaceGroupColor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        hex: String?
    ) -> Bool? {
        colorCalls.append(hex)
        return true
    }

    func controlSetWorkspaceGroupIcon(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        symbol: String?
    ) -> (found: Bool, storedSymbol: String?)? {
        iconCalls.append(symbol)
        return (true, symbol)
    }
}
