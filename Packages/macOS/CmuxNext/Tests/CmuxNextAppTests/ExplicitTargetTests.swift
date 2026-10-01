import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// An explicit target that names nothing fails; a handler never reports
/// success after skipping the work (`cmux workspace rename --target <typo>`)
/// and never falls back to the focused object.
@MainActor
struct ExplicitTargetTests {
    static func run(_ services: AppServices, _ id: String, kind: ActionTargetKind, target: String,
                    arguments: [String: ControlValue] = [:]) -> ControlActionOutcome {
        RegistryControlBridge(registry: services.registry).perform(ControlActionRequest(
            actionID: id, target: ControlTargetRef(kind: kind.rawValue, id: target), arguments: arguments))
    }

    @Test func workspaceVerbsOnAMissingWorkspaceDoNotReportSuccess() {
        let services = ActionBindingCoverageTests.boundServices()
        for id in ["renameWorkspace", "closeWorkspace", "moveWorkspaceUp", "moveWorkspaceDown"] {
            let outcome = Self.run(services, id, kind: .workspace, target: "ws_missing", arguments: ["name": .string("x"), "confirm": .bool(true)])
            #expect(outcome != .ran, "\(id) reported success for a workspace that does not exist")
        }
    }

    @Test func aMissingTargetIsNotFoundAndNeverTheFocusedObject() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(Self.run(services, "renameWorkspace", kind: .workspace, target: "ws_missing", arguments: ["name": .string("x")])
            == .notFound("no workspace ws_missing"))
        #expect(Self.run(services, "tab.focus", kind: .tab, target: "tab_missing") == .notFound("no tab tab_missing"))
    }
}
