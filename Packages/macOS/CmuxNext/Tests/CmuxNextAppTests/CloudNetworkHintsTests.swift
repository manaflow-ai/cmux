import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// The tunnel, network and firewall actions called classic `/api/vm`, deleted from NEXT: each is
/// unavailable and refuses at once with a plain reason, never a wait on a route no Cloud serves.
@MainActor
struct CloudNetworkHintsTests {
    @Test func theRefusalComesFromTheIDArgument() throws {
        #expect(throws: ActionFailure(message: CloudStrings.publicationRequired)) {
            try CloudHandlers.idArgument(ActionInvocation(arguments: ["path": .string("  ")]), CloudStrings.publicationRequired)
        }
        #expect(try CloudHandlers.idArgument(ActionInvocation(arguments: ["path": .string(" pub-1 ")]), CloudStrings.publicationRequired) == "pub-1")
    }

    @Test func theNotYetReasonIsPlain() {
        let reason = CloudStrings.notOnThisCloudYet
        #expect(!reason.isEmpty)
        #expect(!reason.contains("/api/vm") && !reason.contains("--path"))
    }
}
