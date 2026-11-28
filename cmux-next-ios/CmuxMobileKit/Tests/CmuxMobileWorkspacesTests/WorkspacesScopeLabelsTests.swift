import Foundation
import Testing
@testable import CmuxMobileWorkspaces

@Suite struct WorkspacesScopeLabelsTests {
    @Test func allScopeNamesEveryComputer() {
        #expect(!WorkspacesScopeLabels.allComputers.isEmpty)
        #expect(WorkspacesScopeLabels.allComputers != "mobile.workspaces.allComputers")
    }
}
