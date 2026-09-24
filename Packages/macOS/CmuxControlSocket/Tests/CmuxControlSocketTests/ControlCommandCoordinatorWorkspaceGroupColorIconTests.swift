import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for #9594: `workspace.group.set_color` and
/// `workspace.group.set_icon` answered a success-shaped response with a `null`
/// override whenever the request spelled the value key anything other than
/// `hex` / `symbol` — silently clearing the stored value instead of setting it
/// or naming the offending parameter.
///
/// Review follow-ups on the same silent-clear class: colors are normalized to
/// the renderer's canonical `#RRGGBB` spelling (leading `#` optional, since
/// `set-color --hex FF3EA5` already worked through the renderer; short and
/// alpha forms rejected because they store but never render), and echo-back
/// response keys (`custom_color`, `icon_symbol`) plus non-string values return
/// `invalid_params` instead of silently clearing.
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

    @Test func malformedHexLengthsAreRejectedNotApplied() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        // Short and alpha forms would store a value the display path never
        // renders (it only accepts 6-digit RRGGBB), and the off-by-one
        // lengths are not hex colors at all; all must be rejected, not
        // stored or cleared.
        for badValue in ["#F3A", "#F3AB", "#12345", "#1234567", "#FF3EA5C8", "#12", "#123456789"] {
            guard case .err(let code, _, _) = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    "hex": .string(badValue),
                ]
            )) else {
                Issue.record("\(badValue) was not rejected")
                continue
            }
            #expect(code == "invalid_params")
        }
        #expect(context.setColors.isEmpty)

        // Bare 6-digit hex is accepted: the renderer's `normalizedHex` takes
        // it with or without the leading `#`, so rejecting it here would
        // regress `set-color --hex FF3EA5`.
        for goodValue in ["#FF3EA5", "FF3EA5"] {
            guard case .ok = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    "hex": .string(goodValue),
                ]
            )) else {
                Issue.record("\(goodValue) was rejected")
                continue
            }
        }
        #expect(context.setColors.count == 2)
    }

    @Test func bareAndLowercaseHexNormalizeToCanonicalRRGGBB() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        // Whatever spelling arrives, the stored override and the echoed
        // `custom_color` must be the renderer's canonical `#RRGGBB`, so a
        // lowercase or bare value can never sit in storage unrendered.
        for raw in ["FF3EA5", "ff3ea5", "  #ff3ea5  "] {
            guard case .ok(.object(let payload)) = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    "hex": .string(raw),
                ]
            )) else {
                Issue.record("\(raw) was rejected")
                continue
            }
            #expect(context.setColors.last?.hex == "#FF3EA5")
            #expect(payload["custom_color"] == .string("#FF3EA5"))
        }
        #expect(context.setColors.count == 3)
    }

    @Test func customColorEchoKeyAloneIsRejectedNotAClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        // `custom_color` is the response field name; echoing it back alone
        // must return invalid_params instead of reading as a clear.
        for echoed in [JSONValue.string("#FF3EA5"), .null] {
            guard case .err(let code, let message, _) = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    "custom_color": echoed,
                ]
            )) else {
                Issue.record("custom_color-only request was not rejected")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message.contains("hex"))
        }
        #expect(context.setColors.isEmpty)
    }

    @Test func nonStringHexValueIsRejectedNotAClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        for badValue in [JSONValue.int(123), .bool(true), .object(["value": .string("#FF3EA5")])] {
            guard case .err(let code, _, _) = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    "hex": badValue,
                ]
            )) else {
                Issue.record("non-string hex was not rejected")
                continue
            }
            #expect(code == "invalid_params")
        }
        #expect(context.setColors.isEmpty)
    }

    @Test func nullHexAndNullColorStillClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        for key in ["hex", "color"] {
            guard case .ok(.object(let payload)) = coordinator.handle(request(
                "workspace.group.set_color",
                [
                    "group_id": .string(UUID().uuidString),
                    key: .null,
                ]
            )) else {
                Issue.record("null \(key) clear did not succeed")
                continue
            }
            #expect(context.setColors.last?.hex == nil)
            #expect(payload["custom_color"] == .null)
        }
        #expect(context.setColors.count == 2)
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

    @Test func iconSymbolEchoKeyAloneIsRejectedNotAClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        // `icon_symbol` is the response field name; echoing it back alone
        // must return invalid_params instead of reading as a clear.
        for echoed in [JSONValue.string("person.fill"), .null] {
            guard case .err(let code, let message, _) = coordinator.handle(request(
                "workspace.group.set_icon",
                [
                    "group_id": .string(UUID().uuidString),
                    "icon_symbol": echoed,
                ]
            )) else {
                Issue.record("icon_symbol-only request was not rejected")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message.contains("symbol"))
        }
        #expect(context.setIcons.isEmpty)
    }

    @Test func nonStringSymbolValueIsRejectedNotAClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        for badValue in [JSONValue.int(3), .bool(false)] {
            guard case .err(let code, _, _) = coordinator.handle(request(
                "workspace.group.set_icon",
                [
                    "group_id": .string(UUID().uuidString),
                    "symbol": badValue,
                ]
            )) else {
                Issue.record("non-string symbol was not rejected")
                continue
            }
            #expect(code == "invalid_params")
        }
        #expect(context.setIcons.isEmpty)
    }

    @Test func nullSymbolAndNullIconStillClear() {
        let context = FakeWorkspaceGroupColorIconContext()
        let coordinator = ControlCommandCoordinator(context: context)

        for key in ["symbol", "icon"] {
            guard case .ok(.object(let payload)) = coordinator.handle(request(
                "workspace.group.set_icon",
                [
                    "group_id": .string(UUID().uuidString),
                    key: .null,
                ]
            )) else {
                Issue.record("null \(key) clear did not succeed")
                continue
            }
            #expect(context.setIcons.last?.symbol == nil)
            #expect(payload["icon_symbol"] == .null)
        }
        #expect(context.setIcons.count == 2)
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
