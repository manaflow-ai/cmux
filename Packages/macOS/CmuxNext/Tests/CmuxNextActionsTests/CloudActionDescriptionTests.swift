@testable import CmuxNextActions
import Foundation
import Testing

/// Every Cloud action says what it does, what it needs and what it returns
/// (`ActionDescriptor.description`, audit group J): an agent reads it in
/// `cmux action describe` and in the cmux MCP server's tool list.
@Suite struct CloudActionDescriptionTests {
    static let cloud = CloudActionCatalog.descriptors()

    @Test func everyCloudActionHasADescription() {
        for action in Self.cloud {
            let text = action.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #expect(!text.isEmpty, "\(action.id) has no description")
            #expect(text.count <= 600, "\(action.id): a description is a sentence or two")
        }
        let shipped = ActionCatalog.all.filter { CloudActionDescriptions.text[$0.id] != nil }
        #expect(shipped.count == CloudActionDescriptions.text.count, "the catalog carries every description")
        #expect(shipped.allSatisfy { $0.description == CloudActionDescriptions.text[$0.id] })
    }

    @Test func everyDescriptionBelongsToACloudAction() {
        let ids = Set(Self.cloud.map(\.id))
        for id in CloudActionDescriptions.text.keys {
            #expect(ids.contains(id), "\(id) is not a Cloud action")
        }
    }

    /// A description that names a command names one the CLI offers (a verb
    /// that is GUI-only or clipboard-only prints `not_a_verb` and exits 64),
    /// with the `--target machine:<id>` a machine action needs from a script.
    @Test func everyCommandNamedIsOneTheCLIOffers() throws {
        var named = 0
        for action in Self.cloud {
            for mention in (action.description ?? "").components(separatedBy: "`cmux ").dropFirst() {
                let command = try #require(mention.split(separator: "`").first, "\(action.id)")
                let words = command.split(separator: " ").prefix(2).joined(separator: " ")
                let offered = ActionCatalog.all.first { $0.cliName == words }
                #expect(offered?.cli == true, "\(action.id) names `cmux \(words)`, which the CLI does not offer")
                // A CLI or agent run of a machine action must name its machine.
                if offered?.targets.contains(.machine) == true {
                    #expect(command.contains("--target machine:"), "\(action.id) names `cmux \(words)` without --target machine:<id>")
                }
                named += 1
            }
        }
        #expect(named > 0)
    }
}
