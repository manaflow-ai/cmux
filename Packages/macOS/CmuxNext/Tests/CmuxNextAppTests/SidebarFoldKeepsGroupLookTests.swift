import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Review F1 of #39591: a fold makes its group's lines on its own path (`foldLines`), not through a rebuild. It drew
/// them in Automatic's look whatever `sidebar.groupHeader.background` said, so folding a group under Sections showed a
/// rail its header did not have (and under Glass or Solid, or with `sidebar.showColors` off, a look of the default).
/// Every line after a fold and a reopen takes the list's look, as a rebuild's do.
@MainActor @Suite(.serialized) struct SidebarFoldKeepsGroupLookTests {
    typealias Fixture = SidebarIncrementalMatchesRebuildTests

    @Test(arguments: [SidebarGroupBackgroundStyle.sections, .glass, .solid])
    func aFoldKeepsTheGroupBackgroundLook(_ style: SidebarGroupBackgroundStyle) async throws {
        let (sidebar, window) = Fixture.fixture(Fixture.Doc())
        defer { window.close() }
        let list = sidebar.list
        list.model.groupHeaderDetails = GroupHeaderDetails(background: style)
        list.model.showsColors = false
        list.reload(animated: false, fromModel: true)
        for open in [false, true] {
            list.foldGroup(Fixture.work)
            sidebar.renderNow()
            let lines = list.groupLineViews.lines
            let off = lines.filter { $0.background != style || !$0.color.isNone }
            #expect(!lines.isEmpty || !open, "\(style): no lines after the fold")
            #expect(off.isEmpty, "\(style) \(open ? "reopened" : "folded"): lines off the list's look: \(off.map { "\($0.group.rawValue) \($0.background) \($0.color)" })")
        }
    }
}
