import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("DockSourceWorkspaceResolver")
struct DockSourceWorkspaceResolverTests {
    private let repeated = UUID()
    private let unique = UUID()

    private var resolver: DockSourceWorkspaceResolver {
        DockSourceWorkspaceResolver(originalWorkspaceIds: [repeated, nil, repeated, unique])
    }

    @Test("the Dock owner wins among copies of its own ID")
    func dockOwnerWins() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: repeated, dockOwnerIndex: 2) == 2)
    }

    @Test("a Dock that owns no copy resolves to the first copy")
    func nonOwnerResolvesToFirstCopy() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: repeated, dockOwnerIndex: 3) == 0)
    }

    @Test("no Dock owner resolves to the first copy")
    func noOwnerResolvesToFirstCopy() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: repeated) == 0)
    }

    @Test("a unique source ID resolves to its workspace from another Dock")
    func uniqueSourceResolves() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: unique, dockOwnerIndex: 1) == 3)
    }

    @Test("an unknown source ID has no match")
    func unknownSourceHasNoMatch() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: UUID(), dockOwnerIndex: 0) == nil)
    }

    @Test("an out-of-range Dock owner falls back to the source lookup")
    func outOfRangeOwnerFallsBack() {
        #expect(resolver.workspaceIndex(sourceWorkspaceId: unique, dockOwnerIndex: 99) == 3)
    }
}
