import Foundation
import Testing

@testable import CmuxAgentChat

@MainActor
@Suite("Panel artifact authorization")
struct PanelArtifactAuthorizationStoreTests {
    @Test("re-recording replaces the old file and close invalidates the grant")
    func grantFollowsPanelLifecycle() {
        let store = PanelArtifactAuthorizationStore(resolver: FakeResolver())

        store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            filePath: "/safe/first.md"
        )
        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/first.md"
        ) == "/safe/first.md")

        store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            filePath: "/safe/second.md"
        )
        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/first.md"
        ) == nil)
        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/second.md"
        ) == "/safe/second.md")

        store.invalidate(workspaceID: "workspace", surfaceID: "surface")
        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/second.md"
        ) == nil)
    }

    @Test("a different canonical path is denied")
    func pathMismatchIsDenied() {
        let store = PanelArtifactAuthorizationStore(resolver: FakeResolver())
        store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            filePath: "/safe/panel.md"
        )

        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/other.md"
        ) == nil)
        #expect(store.authorizedCanonicalPath(
            workspaceID: "other-workspace",
            surfaceID: "surface",
            requestedPath: "/safe/panel.md"
        ) == nil)
    }

    @Test("symlinks are resolved independently at grant and read time")
    func symlinkTraversalIsDenied() {
        let store = PanelArtifactAuthorizationStore(resolver: FakeResolver(symlinks: [
            "/safe/panel-link.md": "/safe/panel.md",
            "/safe/request-link.md": "/private/secret.md",
        ]))
        store.record(
            workspaceID: "workspace",
            surfaceID: "surface",
            filePath: "/safe/panel-link.md"
        )

        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/request-link.md"
        ) == nil)
        #expect(store.authorizedCanonicalPath(
            workspaceID: "workspace",
            surfaceID: "surface",
            requestedPath: "/safe/panel-link.md"
        ) == "/safe/panel.md")
    }

    private struct FakeResolver: ChatArtifactScope.FileSystemResolving {
        var symlinks: [String: String] = [:]

        func resolveSymlinks(of path: String) -> String? {
            ((symlinks[path] ?? path) as NSString).standardizingPath
        }

        func isDirectory(_ path: String) -> Bool? {
            false
        }
    }
}
