import Foundation
import Testing

@testable import CmuxNextAgentPane

@Suite struct AgentPaneRequestDescriptionTests {
    @Test func descriptionsNeverIncludeAssociatedUserContent() {
        let secret = "secret-user-content-123"
        let requests: [AgentPaneRequest] = [
            .unsentDraft(secret, attachments: [], attachmentsProvided: true),
            .typeAhead(secret),
            .shellRun(command: secret, cwd: "/tmp/\(secret)"),
            .openPreview(URL(string: "http://127.0.0.1/?token=\(secret)")!),
        ]

        for request in requests {
            #expect(!String(describing: request).contains(secret))
            #expect(!String(reflecting: request).contains(secret))
            #expect(!request.debugDescription.contains(secret))
            #expect(Array(Mirror(reflecting: request).children).isEmpty)
            var dumped = ""
            dump(request, to: &dumped)
            #expect(!dumped.contains(secret))
        }
    }

    @Test func descriptionKeepsTheCaseNameOnly() {
        #expect(String(describing: AgentPaneRequest.ready) == "ready")
    }
}
