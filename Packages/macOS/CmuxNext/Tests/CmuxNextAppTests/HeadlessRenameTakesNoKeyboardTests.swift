import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing

/// A rename that names no name opens an editor for the person (the sidebar's inline field, the
/// palette's name step for a tab). A headless run (CLI, socket, MCP without focus) must never take the keyboard
/// (OWNERSHIP-PRINCIPLES), but `renameWorkspace {name: ""}` from the socket moved the window's first
/// responder from the terminal into the sidebar's rename field, and brought its window forward
/// when it was not the active one (QA spree 2026-10-23, F25). The person's Rename still opens it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HeadlessRenameTakesNoKeyboardTests {
    static func responder(_ controller: WindowController) -> FocusEvent.Responder {
        FocusResponderClassifier.classify(controller.window?.firstResponder, in: controller)
    }

    /// The first responder itself (a field inside a pane classifies as the pane's content).
    static func responderObject(_ controller: WindowController) -> ObjectIdentifier? {
        controller.window?.firstResponder.map(ObjectIdentifier.init)
    }

    @Test(arguments: ["renameWorkspace", "renameTab"])
    func aHeadlessRenameWithNoNameOpensNoEditor(_ action: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until({ controller.focus.state.resolved.tab != nil },
                                                      report: { "focus \(controller.focus.state.resolved)" })
            let target = action == "renameTab"
                ? ActionTargetRef(kind: .tab, id: try #require(controller.focus.state.resolved.tab))
                : ActionTargetRef(kind: .workspace, id: try #require(controller.state.workspaceID))
            let before = Self.responder(controller)
            let beforeObject = Self.responderObject(controller)
            #expect(before != .sidebarField)

            let headless = ActionInvocation(target: target, arguments: ["name": .string("")], origin: .cli)
            #expect(!services.registry.perform(ActionID(rawValue: action), invocation: headless), "a headless rename with no name ran")
            #expect(Self.responder(controller) == before, "a headless rename moved the keyboard to \(Self.responder(controller))")
            #expect(Self.responderObject(controller) == beforeObject,
                    "a headless rename moved the keyboard to \(controller.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")

            // A person's Rename (menu, palette, keybind) still opens the editor: the sidebar's field takes the
            // keyboard. (A tab's is a palette step, whose panel this harness never orders in.)
            let person = ActionInvocation(target: target, arguments: ["name": .string("")])
            #expect(services.registry.perform(ActionID(rawValue: action), invocation: person), "a person's rename was refused")
            if action == "renameWorkspace" {
                try await PasswordManagerRouteTests.until({ Self.responder(controller) == .sidebarField },
                                                          report: { "responder \(Self.responder(controller))" })
            }
        }
    }
}
