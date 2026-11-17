import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextCloud
import Foundation
import Testing

/// The firewall actions called classic `/api/vm/firewall`, deleted from NEXT: each is unavailable
/// and refuses at once with a plain reason, never a wait on a route no Cloud serves. Tunnel attach
/// and detach go through acpmux and take an optional network id.
@MainActor
struct CloudNetworkHintsTests {
    @Test func theRefusalComesFromTheIDArgument() throws {
        #expect(throws: ActionFailure(message: CloudStrings.publicationRequired)) {
            try CloudHandlerRules().id(ActionInvocation(arguments: ["path": .string("  ")]), missing: "publicationRequired")
        }
        #expect(try CloudHandlerRules().id(ActionInvocation(arguments: ["path": .string(" pub-1 ")]), missing: "publicationRequired") == "pub-1")
    }

    /// Attach and detach take no required id: none is the joined team's network, the only one
    /// acpmux's tunnel joins (a given id must be that team's).
    @Test func theTunnelNetworkIsOptional() throws {
        for id: ActionID in ["cloudTunnelAttach", "cloudTunnelDetach"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.arguments.map(\.name) == ["path"], "\(id)")
            #expect(descriptor.arguments.allSatisfy { !$0.isRequired }, "\(id) runs with no network id")
        }
    }

    @Test func theNotYetReasonIsPlain() {
        let reason = CloudStrings.firewallNotOnThisCloudYet
        #expect(!reason.isEmpty)
        #expect(!reason.contains("/api/vm") && !reason.contains("--path"))
    }
}
