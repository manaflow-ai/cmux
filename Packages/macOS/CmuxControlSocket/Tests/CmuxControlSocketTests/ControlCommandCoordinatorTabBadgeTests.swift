import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator tab badge actions")
struct ControlCommandCoordinatorTabBadgeTests {
    private func completed(_ extras: ControlTabActionResolution.Extras, surfaceID: UUID) -> ControlTabActionResolution {
        .completed(ControlTabActionResolution.Outcome(
            workspaceID: UUID(),
            surfaceID: surfaceID,
            windowID: UUID(),
            paneID: UUID(),
            extras: extras
        ))
    }

    @Test func setBadgeForwardsTrimmedBadgeAndReportsIt() throws {
        let surfaceID = UUID()
        let context = FakeTabActionControlCommandContext()
        context.resolution = completed(.badge("🦀", color: "#BB9AF7"), surfaceID: surfaceID)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: [
                "action": .string("set-badge"),
                "surface_id": .string(surfaceID.uuidString),
                "badge": .string("  🦀 "),
                "color": .string(" lavender "),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected successful tab.action payload")
            return
        }
        #expect(context.actionKey == "set_badge")
        #expect(context.badge == "🦀")
        #expect(context.badgeColor == "lavender")
        #expect(context.surfaceID == surfaceID)
        #expect(payload["action"] == .string("set_badge"))
        #expect(payload["badge"] == .string("🦀"))
        #expect(payload["badge_color"] == .string("#BB9AF7"))
        #expect(payload["tab_id"] == .string(surfaceID.uuidString))
    }

    @Test func clearBadgeReportsNullBadge() throws {
        let surfaceID = UUID()
        let context = FakeTabActionControlCommandContext()
        context.resolution = completed(.badge(nil, color: nil), surfaceID: surfaceID)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: [
                "action": .string("clear_badge"),
                "surface_id": .string(surfaceID.uuidString),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected successful tab.action payload")
            return
        }
        #expect(context.actionKey == "clear_badge")
        #expect(context.badge == nil)
        #expect(payload["badge"] == .null)
        #expect(payload["badge_color"] == .null)
    }

    @Test func invalidBadgeReturnsInvalidParamsWithLimit() {
        let context = FakeTabActionControlCommandContext()
        context.resolution = .invalidBadge(maximumCharacters: 16)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: ["action": .string("set_badge")]
        ))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid badge error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message.contains("badge"))
        #expect(data == .object(["max_characters": .int(16)]))
    }

    @Test func invalidBadgeColorListsNamedColors() {
        let context = FakeTabActionControlCommandContext()
        context.resolution = .invalidBadgeColor(namedColors: ["Red", "Blue"])
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: ["action": .string("set_badge"), "badge": .string("🦀"), "color": .string("nope")]
        ))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid badge color error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message.contains("color"))
        #expect(data == .object(["named_colors": .array([.string("Red"), .string("Blue")])]))
    }

    @Test func unknownTabActionAdvertisesBadgeActions() {
        let context = FakeTabActionControlCommandContext()
        context.resolution = .unknownAction
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: ["action": .string("unknown")]
        ))

        guard case .err(_, _, .object(let payload)?) = result,
              case .array(let supportedActions)? = payload["supported_actions"] else {
            Issue.record("expected supported_actions payload")
            return
        }
        #expect(supportedActions.contains(.string("set_badge")))
        #expect(supportedActions.contains(.string("clear_badge")))
    }
}
