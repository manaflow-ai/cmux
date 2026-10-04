import Foundation
import Testing
@testable import CmuxNextApp

/// cmux-page:// first-party pages for Chromium tabs: a reserved host is
/// served only from its bundled resource root, and only for an id in the
/// first-party table (CmuxNextPages PageID).
@MainActor
@Suite struct FirstPartyPageSchemesTests {
    /// A fake app bundle: Resources/agent-pane, plus a sibling Resources2
    /// and an outside folder.
    private func fixture() throws -> (resources: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "fpps-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resources = base.appending(path: "Resources", directoryHint: .isDirectory)
        for folder in ["Resources/agent-pane", "Resources2/agent-pane", "outside"] {
            try FileManager.default.createDirectory(at: base.appending(path: folder), withIntermediateDirectories: true)
        }
        return (resources, base)
    }

    @Test func aReservedIdWithANonBundledRootIsRefused() throws {
        let (resources, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agent", root: base.appending(path: "outside"), bundleResources: resources)
            == .outsideBundle("cmux.agent"))
        // A string prefix of the resource folder is not inside it.
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agent", root: base.appending(path: "Resources2/agent-pane"), bundleResources: resources)
            == .outsideBundle("cmux.agent"))
        // Nor is the resource folder itself, or a path that climbs out of it.
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agent", root: resources, bundleResources: resources)
            == .outsideBundle("cmux.agent"))
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agent", root: resources.appending(path: "../outside"), bundleResources: resources)
            == .outsideBundle("cmux.agent"))
    }

    @Test func aBundledFirstPartyPageIsAccepted() throws {
        let (resources, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agent", root: resources.appending(path: "agent-pane"), bundleResources: resources) == nil)
    }

    @Test func onlyIdsOfTheFirstPartyTableUseThisPath() throws {
        let (resources, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = resources.appending(path: "agent-pane")
        // Reserved but no shipped page: refused.
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.agentx", root: root, bundleResources: resources) == .notFirstParty("cmux.agentx"))
        // An app id never goes through the first-party export.
        #expect(FirstPartyPageSchemes.refusal(id: "com.example.app", root: root, bundleResources: resources) == .notReserved("com.example.app"))
    }

    /// cmux.agent maps to the agent pane's bundled page folder, and nothing
    /// outside the reserved namespace is in the table.
    @Test func cmuxAgentServesTheAgentPaneBundle() throws {
        let roots = FirstPartyPageSchemes.bundledRoots()
        let agent = try #require(roots["cmux.agent"])
        #expect(agent == FirstPartyPageSchemes.agentPaneRoot)
        #expect(agent.lastPathComponent == "agent-pane")
        #expect(FileManager.default.fileExists(atPath: agent.appending(path: "index.html").path))
        #expect(roots.keys.allSatisfy { $0.hasPrefix("cmux.") })
    }

    @Test func registrationSkipsRefusedRoots() throws {
        let (resources, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let accepted = FirstPartyPageSchemes.accepted(
            roots: ["cmux.agent": resources.appending(path: "agent-pane"), "cmux.history": base.appending(path: "outside")],
            bundleResources: resources
        )
        #expect(accepted.keys.sorted() == ["cmux.agent"])
    }
}
