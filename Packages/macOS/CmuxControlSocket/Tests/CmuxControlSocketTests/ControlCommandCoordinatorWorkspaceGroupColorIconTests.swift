import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for #9594: `workspace.group.set_color` and
/// `workspace.group.set_icon` answered a success-shaped response with a `null`
/// override whenever the request spelled the value key anything other than
/// `hex` / `symbol` — silently clearing the stored value instead of setting it
/// or naming the offending parameter.
@MainActor
@Suite("Control command workspace-group color and icon setters")
struct ControlCommandCoordinatorWorkspaceGroupColorIconTests {
    @Test func colorAliasSetsTheOverride() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.set_color",
            [
                "group_id": .string(groupID.uuidString),
                "color": .string("#FF3EA5"),
            ]
        )) else {
            Issue.record("set_color via the `color` alias did not succeed")
            return
        }

        #expect(context.setColors.count == 1)
        #expect(context.setColors.first?.groupID == groupID)
        #expect(context.setColors.first?.hex == "#FF3EA5")
        #expect(payload["custom_color"] == .string("#FF3EA5"))
    }

    @Test func hexRemainsTheCanonicalKey() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.set_color",
            [
                "group_id": .string(UUID().uuidString),
                "hex": .string("#FF3EA5"),
            ]
        )) else {
            Issue.record("set_color via `hex` did not succeed")
            return
        }

        #expect(context.setColors.first?.hex == "#FF3EA5")
        #expect(payload["custom_color"] == .string("#FF3EA5"))
    }

    @Test func emptyHexStillClears() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.set_color",
            [
                "group_id": .string(UUID().uuidString),
                "hex": .string(""),
            ]
        )) else {
            Issue.record("set_color clear did not succeed")
            return
        }

        #expect(context.setColors.first?.hex == nil)
        #expect(payload["custom_color"] == .null)
    }

    @Test func nonHexColorValueIsRejectedNamingTheParameter() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(let code, let message, let data) = coordinator.handle(request(
            "workspace.group.set_color",
            [
                "group_id": .string(UUID().uuidString),
                "color": .string("Magenta"),
            ]
        )) else {
            Issue.record("named-color set_color was not rejected")
            return
        }

        #expect(code == "invalid_params")
        #expect(message.contains("color"))
        #expect(context.setColors.isEmpty)
        guard case .object(let errData) = data else {
            Issue.record("rejection did not name the offending parameter")
            return
        }
        #expect(errData["color"] == .string("Magenta"))
    }

    @Test func nonHexHexValueIsRejectedNamingTheParameter() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.group.set_color",
            [
                "group_id": .string(UUID().uuidString),
                "hex": .string("Magenta"),
            ]
        )) else {
            Issue.record("named-color set_color via `hex` was not rejected")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.setColors.isEmpty)
    }

    @Test func iconAliasSetsTheSymbol() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()
        context.storedIconSymbol = "person.fill"

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.set_icon",
            [
                "group_id": .string(groupID.uuidString),
                "icon": .string("person.fill"),
            ]
        )) else {
            Issue.record("set_icon via the `icon` alias did not succeed")
            return
        }

        #expect(context.setIcons.first?.groupID == groupID)
        #expect(context.setIcons.first?.symbol == "person.fill")
        #expect(payload["icon_symbol"] == .string("person.fill"))
    }

    @Test func symbolRemainsTheCanonicalKey() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.storedIconSymbol = "person.fill"

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.set_icon",
            [
                "group_id": .string(UUID().uuidString),
                "symbol": .string("person.fill"),
            ]
        )) else {
            Issue.record("set_icon via `symbol` did not succeed")
            return
        }

        #expect(context.setIcons.first?.symbol == "person.fill")
        #expect(payload["icon_symbol"] == .string("person.fill"))
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}

@MainActor
private final class FakeWorkspaceGroupColorIconContext: ControlCommandContext {
    struct ColorCall {
        var groupID: UUID
        var hex: String?
    }

    struct IconCall {
        var groupID: UUID
        var symbol: String?
    }

    var setColors: [ColorCall] = []
    var setIcons: [IconCall] = []
    var storedIconSymbol: String?

    func controlSetWorkspaceGroupColor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        hex: String?
    ) -> Bool? {
        setColors.append(ColorCall(groupID: groupID, hex: hex))
        return true
    }

    func controlSetWorkspaceGroupIcon(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        symbol: String?
    ) -> (found: Bool, storedSymbol: String?)? {
        setIcons.append(IconCall(groupID: groupID, symbol: symbol))
        return (true, storedIconSymbol)
    }
}
