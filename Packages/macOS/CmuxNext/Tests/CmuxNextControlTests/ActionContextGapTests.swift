import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `action.list` and `action.describe` say why an action is unavailable in
/// the current context. A Cloud machine action with no Cloud workspace focused
/// used to read `available: false` with no reason, though it runs with
/// `--target machine:<id>`; it now names the missing context and the target
/// kind that supplies it.
@Suite struct ActionContextGapTests {
    static func action(requires: ActionContext, targets: [String]) -> ControlActionInfo {
        ControlActionInfo(id: "cloudPauseMachine", title: "Pause Machine", category: "cloud", categoryTitle: "Cloud",
                          cliName: "cloud pause-machine", symbol: "pause.circle", keywords: [], shortcut: nil, shortcutConfig: nil,
                          arguments: [], targets: targets, requiresMask: requires.rawValue, requires: ["cloudWorkspace"],
                          isBound: true, isDebugOnly: false, mainMenu: nil)
    }

    @Test func aMachineActionWithNoCloudWorkspaceSaysATargetSuppliesIt() throws {
        let json = Self.action(requires: .cloudWorkspace, targets: ["machine"]).json(contextMask: 0, debugActionsAvailable: false)
        #expect(json["available"] == false)
        #expect(json["missing_context"] == .array(["cloudWorkspace"]))
        #expect(json["available_with_target"] == .array(["machine"]))
        let reason = try #require(json["context_reason"]?.stringValue)
        #expect(reason.contains("--target machine:<id>"))
    }

    @Test func anActionWhoseTargetCannotSupplyTheContextSaysOnlyWhatIsMissing() throws {
        let json = Self.action(requires: .cloudWorkspace, targets: ["tab"]).json(contextMask: 0, debugActionsAvailable: false)
        #expect(json["missing_context"] == .array(["cloudWorkspace"]))
        #expect(json["available_with_target"] == nil)
        #expect(try #require(json["context_reason"]?.stringValue).contains("cloudWorkspace"))
    }

    @Test func anAvailableActionCarriesNoGap() {
        let json = Self.action(requires: .cloudWorkspace, targets: ["machine"])
            .json(contextMask: ActionContext.cloudWorkspace.rawValue, debugActionsAvailable: false)
        #expect(json["available"] == true)
        #expect(json["missing_context"] == nil)
        #expect(json["context_reason"] == nil)
    }
}
