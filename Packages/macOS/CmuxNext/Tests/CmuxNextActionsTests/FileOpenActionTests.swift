import CmuxNextActions
import Testing

/// `file.open` (#16723): the agent pane's changed files open through the
/// registry, so the palette, `cmux file open` and MCP reach the same path.
@Suite struct FileOpenActionTests {
    @Test func fileOpenIsAnActionWithItsSurfaces() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "file.open" }, "file.open is not in the catalog")
        #expect(descriptor.cliName == "file open")
        #expect(descriptor.targets == [.pane])
        let plan = descriptor.surfacePlan
        #expect(plan.palette == .offered)
        #expect(plan.cli == .offered)
        #expect(plan.mcp == .offered)
        // A changed file has no native right-click surface; the page's file menu calls the action.
        #expect(plan.contextMenu == .exempt(.noTargetSurface))
    }

    @Test func fileOpenTakesAPathAndWhereToOpenIt() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "file.open" }, "file.open is not in the catalog")
        let path = try #require(descriptor.arguments.first { $0.name == "path" })
        #expect(path.kind == .string)
        #expect(path.isRequired)
        let place = try #require(descriptor.arguments.first { $0.name == "where" })
        guard case .enumeration(let cases) = place.kind else {
            Issue.record("where is not a choice")
            return
        }
        #expect(cases.map(\.value) == ["tab", "editor"])
        #expect(!place.isRequired)
    }
}
