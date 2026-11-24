import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

struct WorkspaceRowLayoutSettingsTests {
    static func parse(_ json: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
                                 validDensities: [], validMetrics: [])
    }

    @Test func agentThenKindThenGlobalUsesTheRealRustReducer() throws {
        let snapshot = try Self.parse(#"{"sidebar":{"workspaceRow":{"lines":[["name","branch"]],"linesByKind":{"agent":[["name"],["directory"]]},"linesByAgent":{"codex":[["icon","name","working"],["log"],["pullRequest"]]}}}}"#)
        let rows = snapshot.sidebarSections.workspaceRow
        #expect(snapshot.diagnostics.isEmpty)
        let agent = try #require(rows.layouts.layout(for: .agent, agent: "codex"))
        #expect(agent.lines == [["name"], ["log"], ["pullRequest"]])
        #expect(agent.slots.icon && agent.slots.working)
        #expect(rows.layouts.layout(for: .agent, agent: "claude")?.lines == [["name"], ["directory"]])
        #expect(rows.layouts.layout(for: .terminal, agent: nil)?.lines == [["name", "branch"]])
        #expect(rows.showsAnywhere(.log))
    }

    @Test func invalidAndNullAgentCandidatesFallThroughInRust() throws {
        let snapshot = try Self.parse(#"{"sidebar":{"workspaceRow":{"lines":[["name"]],"linesByKind":{"agent":[["name"],["branch"]]},"linesByAgent":{"codex":42,"claude":null}}}}"#)
        let rows = snapshot.sidebarSections.workspaceRow.layouts
        #expect(rows.layout(for: .agent, agent: "codex")?.lines == [["name"], ["branch"]])
        #expect(rows.layout(for: .agent, agent: "claude")?.lines == [["name"], ["branch"]])
        #expect(snapshot.diagnostics.filter { $0.path == "sidebar.workspaceRow.linesByAgent.codex" }.count == 1)
        #expect(!snapshot.diagnostics.contains { $0.message.contains("unavailable") })
    }

    @Test func reducerNormalizationCannotSilentlyFallBackToLegacyDefaults() throws {
        let snapshot = try Self.parse(#"{"sidebar.workspaceRow.lines":[["icon","branch","unknown"],["name","branch","working"]]}"#)
        let layout = try #require(snapshot.sidebarSections.workspaceRow.layouts.layout(for: .browser, agent: nil))
        #expect(layout.lines == [["name", "branch"]])
        #expect(layout.slots.icon && layout.slots.working)
        #expect(snapshot.diagnostics.contains { $0.message.contains("unknownToken") })
        #expect(snapshot.diagnostics.contains { $0.message.contains("nameMoved") })
    }

    @Test func removingLayoutKeepsTheExistingElementSwitches() throws {
        let snapshot = try Self.parse(#"{"sidebar":{"workspaceRow":{"lines":null,"directory":true}}}"#)
        #expect(snapshot.sidebarSections.workspaceRow.layouts.kinds.isEmpty)
        #expect(snapshot.sidebarSections.workspaceRow.resolved(for: .terminal).shows(.directory))
        #expect(snapshot.diagnostics.isEmpty)
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkspaceRowLayoutWatcherTests {
    @Test func atomicSavesApplyAndRemoveTheLayoutWithoutRestarting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-row-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux-next.json")
        try Data(#"{}"#.utf8).write(to: file)
        let design = DesignSettings()
        let settings = SettingsController(registry: .standard(), design: design, fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        settings.start()
        defer { settings.stop() }
        await settings.waitForLoad(atLeast: 1)
        var generation = settings.loadCount + 1
        let updated = #"{"sidebar":{"workspaceRow":{"linesByAgent":{"codex":[["name","working"],["branch"]]}}}}"#
        try Data(updated.utf8).write(to: file, options: .atomic)
        await settings.waitForLoad(atLeast: generation)
        #expect(design.sidebarSections.workspaceRow.layouts.layout(for: .agent, agent: "codex")?.lines == [["name"], ["branch"]])
        generation = settings.loadCount + 1
        try Data(#"{}"#.utf8).write(to: file, options: .atomic)
        await settings.waitForLoad(atLeast: generation)
        #expect(design.sidebarSections.workspaceRow == .defaults)
    }
}
