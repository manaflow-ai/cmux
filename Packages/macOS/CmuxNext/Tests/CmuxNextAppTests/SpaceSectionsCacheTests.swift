import Foundation
import Observation
import Testing
@testable import CmuxNextApp
import CmuxNextSidebar

/// R99 (coordinator decision): the rows of the space beside the current
/// one are read once per swipe and cached; the same observed data that
/// built them (daemon stores, personal rows) clears the entry. No polling.
@MainActor @Suite struct SpaceSectionsCacheTests {
    @Observable final class Source { var title = "one" }

    static func sections(_ title: String) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                        nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w"), title: title))])]
    }

    @Test func aRepeatedReadIsCachedAndAChangeOfItsDataClearsIt() async {
        let cache = SpaceSectionsCache()
        let source = Source()
        let key = ProfileKey("work")
        let compute = { Self.sections(source.title) }
        #expect(cache.sections(for: key, compute: compute).first?.workspaces.first?.title == "one")
        #expect(cache.sections(for: key, compute: compute).first?.workspaces.first?.title == "one")
        #expect(cache.computations == 1, "the second read is the cached one")
        source.title = "two"
        for _ in 0..<50 { await Task.yield() }
        #expect(cache.sections(for: key, compute: compute).first?.workspaces.first?.title == "two")
        #expect(cache.computations == 2)
    }
}
