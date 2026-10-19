import Foundation
import Testing

@testable import CmuxNextAgentPane

@Suite struct AgentPaneRequestDescriptionTests {
    @Test func descriptionsNeverIncludeAssociatedUserContent() {
        let secret = "secret-user-content-123"
        let requests: [AgentPaneRequest] = [
            .unsentDraft(secret),
            .typeAhead(secret),
            .shellRun(command: secret, cwd: "/tmp/\(secret)"),
            .openPreview(URL(string: "http://127.0.0.1/?token=\(secret)")!),
        ]

        for request in requests {
            #expect(!String(describing: request).contains(secret))
        }
    }
}
