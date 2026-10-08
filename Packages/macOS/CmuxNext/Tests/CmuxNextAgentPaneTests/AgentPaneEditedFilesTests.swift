import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `agentPane.editedFiles.*` reaches the page as the `editedFiles` event on the page host and as
/// `window.cmuxAcpmuxEditedFiles(value)` on the old host, both with the value the page's
/// turnChanges/settings.ts reads: `{show, maxRows, scope}`.
@MainActor
@Suite struct AgentPaneEditedFilesTests {
    static var session: AgentPaneEditedFilesSetting {
        var setting = AgentPaneEditedFilesSetting()
        setting.show = "never"
        setting.maxRows = 9
        setting.scope = "session"
        return setting
    }

    @Test func theEventCarriesTheThreeKeys() {
        let event = AgentPageEvent.editedFiles(Self.session)
        #expect(event.kind == "editedFiles")
        #expect(event.value == ["show": "never", "maxRows": 9, "scope": "session"])
    }

    @Test func theOldHostScriptCallsThePagesSetter() throws {
        let script = AgentPaneView.editedFilesScript(Self.session)
        let prefix = "window.cmuxAcpmuxEditedFiles?.("
        #expect(script.hasPrefix(prefix) && script.hasSuffix(");"))
        let json = String(script.dropFirst(prefix.count).dropLast(2))
        #expect(try JSONValue.parse(Data(json.utf8)) == ["show": "never", "maxRows": 9, "scope": "session"])
    }
}
