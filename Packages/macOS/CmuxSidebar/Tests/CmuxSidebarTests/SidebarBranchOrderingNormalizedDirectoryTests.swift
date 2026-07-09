import Foundation
import Testing

@testable import CmuxSidebar

/// Behavior pins for the now-public ``SidebarBranchOrdering/normalizedDirectory(_:)``,
/// the single owner of the sidebar directory-normalization rule that the
/// app-target `Workspace` shim routes its live-resolved directory strings
/// through (drained from the legacy `Workspace.normalizedSidebarDirectory(_:)`).
@Suite
struct SidebarBranchOrderingNormalizedDirectoryTests {
    @Test
    func normalizedDirectoryReturnsNilForNil() {
        #expect(SidebarBranchOrdering().normalizedDirectory(nil) == nil)
    }

    @Test
    func normalizedDirectoryReturnsNilForWhitespaceOnly() {
        #expect(SidebarBranchOrdering().normalizedDirectory("   \n\t ") == nil)
        #expect(SidebarBranchOrdering().normalizedDirectory("") == nil)
    }

    @Test
    func normalizedDirectoryTrimsSurroundingWhitespaceAndNewlines() {
        #expect(SidebarBranchOrdering().normalizedDirectory("  /Users/me/proj \n") == "/Users/me/proj")
        #expect(SidebarBranchOrdering().normalizedDirectory("/Users/me/proj") == "/Users/me/proj")
    }

    @Test
    func normalizedDirectoryPreservesInteriorWhitespace() {
        #expect(SidebarBranchOrdering().normalizedDirectory("  /Users/me/my proj ") == "/Users/me/my proj")
    }
}
