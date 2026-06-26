import Foundation
import Testing

@testable import CmuxSidebar

/// A configurable in-test ``SidebarMetadataHosting`` standing in for the
/// app-target `Workspace`, so the resolver's directory/canonicalization logic
/// can be exercised without the live workspace.
@MainActor
private final class FakeSidebarHost: SidebarMetadataHosting {
    var sidebarFocusedPanelId: UUID?
    var sidebarCurrentDirectory: String
    var sidebarIsRemoteWorkspace: Bool
    var panelDirectories: [UUID: String]
    var requestedDirectories: [UUID: String]
    var sidebarSpatialPanelOrder: [UUID] = []
    var sidebarVisibleStatusEntriesForDisplay: [SidebarStatusEntry] = []

    init(
        focusedPanelId: UUID? = nil,
        currentDirectory: String = "",
        isRemoteWorkspace: Bool = false,
        panelDirectories: [UUID: String] = [:],
        requestedDirectories: [UUID: String] = [:]
    ) {
        self.sidebarFocusedPanelId = focusedPanelId
        self.sidebarCurrentDirectory = currentDirectory
        self.sidebarIsRemoteWorkspace = isRemoteWorkspace
        self.panelDirectories = panelDirectories
        self.requestedDirectories = requestedDirectories
    }

    func sidebarPanelDirectory(for panelId: UUID) -> String? {
        panelDirectories[panelId]
    }

    func sidebarPanelRequestedWorkingDirectory(for panelId: UUID) -> String? {
        requestedDirectories[panelId]
    }

    func sidebarIsRemoteDisplaySurface(_ panelId: UUID) -> Bool {
        false
    }
}

@MainActor
@Suite struct SidebarDirectoryResolverTests {
    @Test func resolvedDirectoryPrefersReportedDirectoryTrimmed() {
        let panel = UUID()
        let host = FakeSidebarHost(panelDirectories: [panel: "  /work/repo \n"])
        let resolver = SidebarDirectoryResolver(host: host)
        #expect(resolver.resolvedDirectory(for: panel) == "/work/repo")
    }

    @Test func resolvedDirectoryFallsBackToRequestedWorkingDirectory() {
        let panel = UUID()
        let host = FakeSidebarHost(requestedDirectories: [panel: "/req/dir"])
        let resolver = SidebarDirectoryResolver(host: host)
        #expect(resolver.resolvedDirectory(for: panel) == "/req/dir")
    }

    @Test func resolvedDirectoryUsesCurrentDirectoryOnlyForFocusedPanel() {
        let focused = UUID()
        let other = UUID()
        let host = FakeSidebarHost(focusedPanelId: focused, currentDirectory: "/cur/dir")
        let resolver = SidebarDirectoryResolver(host: host)
        #expect(resolver.resolvedDirectory(for: focused) == "/cur/dir")
        #expect(resolver.resolvedDirectory(for: other) == nil)
    }

    @Test func resolvedPanelDirectoriesOmitsUnresolvablePanels() {
        let withDir = UUID()
        let withoutDir = UUID()
        let host = FakeSidebarHost(panelDirectories: [withDir: "/a"])
        let resolver = SidebarDirectoryResolver(host: host)
        let resolved = resolver.resolvedPanelDirectories(orderedPanelIds: [withDir, withoutDir])
        #expect(resolved == [withDir: "/a"])
    }

    @Test func homeDirectoryForCanonicalizationLocalIsCurrentUserHome() {
        let host = FakeSidebarHost(isRemoteWorkspace: false)
        let resolver = SidebarDirectoryResolver(host: host)
        #expect(
            resolver.homeDirectoryForCanonicalization(resolvedPanelDirectories: [:])
                == FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    @Test func homeDirectoryForCanonicalizationRemoteInfersFromDirectories() {
        let p1 = UUID()
        let p2 = UUID()
        let host = FakeSidebarHost(isRemoteWorkspace: true)
        let resolver = SidebarDirectoryResolver(host: host)
        // Tilde-form and absolute-form of the same path agree on /root.
        let resolved: [UUID: String] = [p1: "~/proj", p2: "/root/proj"]
        #expect(
            resolver.homeDirectoryForCanonicalization(resolvedPanelDirectories: resolved) == "/root"
        )
    }
}
