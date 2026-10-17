import CmuxNextApps
import Foundation
import Testing
@testable import CmuxNextApp

struct AgentCLIAppOpsTests {
    @Test func inventoryIsBoundedAndUsesAccountLabels() {
        let accounts: AppJSON = [
            [
                "provider": "codex",
                "account": "acct_test",
                "label": "Work",
                "status": "signed_in",
                "plan": "team",
            ],
        ]
        let result = AgentCLIAppOps.list(accounts: accounts, environment: ["PATH": "/bin"], home: URL(fileURLWithPath: "/Users/test"))
        let clis = result["clis"]?.arrayValue ?? []
        let codex = clis.first { $0["cli"]?.stringValue == "codex" }
        #expect(codex?["installed"]?.boolValue == false)
        #expect(codex?["accounts"]?.arrayValue?.first?["label"]?.stringValue == "Work")
        #expect(codex?["accounts"]?.arrayValue?.first?["account"]?.stringValue == "acct_test")
        #expect(codex?["version"]?.isNull == true)
        #expect(codex?["path_label"] == nil)
    }
}
