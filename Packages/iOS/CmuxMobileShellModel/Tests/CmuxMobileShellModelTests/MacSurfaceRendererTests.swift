import CMUXMobileCore
import Testing
@testable import CmuxMobileShellModel

struct MacSurfaceRendererTests {
    private func surface(
        kind: MobileSurfacePreview.Kind,
        filePath: String? = nil,
        todo: MobileTodoSnapshot? = nil
    ) -> MobileSurfacePreview {
        MobileSurfacePreview(
            id: "surface-1",
            kind: kind,
            title: "Surface",
            filePath: filePath,
            todo: todo
        )
    }

    private var todoSnapshot: MobileTodoSnapshot {
        MobileTodoSnapshot(status: .todo, statusHidden: false, items: [])
    }

    @Test func todoWithCapabilityAndSnapshotRendersNatively() {
        let renderer = MacSurfaceRenderer.resolve(
            surface: surface(kind: .todo, todo: todoSnapshot),
            supportsTodo: true,
            supportsPanelArtifacts: true
        )
        #expect(renderer == .todo(todoSnapshot))
    }

    @Test func todoWithoutCapabilityStillRendersSnapshot() {
        // The capability set empties while a connection recovers; the synced
        // snapshot must keep rendering (mutations are gated at the view layer).
        let renderer = MacSurfaceRenderer.resolve(
            surface: surface(kind: .todo, todo: todoSnapshot),
            supportsTodo: false,
            supportsPanelArtifacts: true
        )
        #expect(renderer == .todo(todoSnapshot))
    }

    @Test func todoWithoutSnapshotFallsBackToCard() {
        let renderer = MacSurfaceRenderer.resolve(
            surface: surface(kind: .todo),
            supportsTodo: true,
            supportsPanelArtifacts: true
        )
        #expect(renderer == .fallbackCard)
    }

    @Test func filePreviewWithCapabilityAndPathRendersNatively() {
        let renderer = MacSurfaceRenderer.resolve(
            surface: surface(kind: .filePreview, filePath: "/tmp/demo.txt"),
            supportsTodo: false,
            supportsPanelArtifacts: true
        )
        #expect(renderer == .filePreview(path: "/tmp/demo.txt"))
    }

    @Test func markdownWithCapabilityAndPathRendersNatively() {
        let renderer = MacSurfaceRenderer.resolve(
            surface: surface(kind: .markdown, filePath: "/tmp/demo.md"),
            supportsTodo: false,
            supportsPanelArtifacts: true
        )
        #expect(renderer == .markdown(path: "/tmp/demo.md"))
    }

    @Test func fileBackedKindsWithoutCapabilityFallBackToCard() {
        for kind in [MobileSurfacePreview.Kind.filePreview, .markdown] {
            let renderer = MacSurfaceRenderer.resolve(
                surface: surface(kind: kind, filePath: "/tmp/demo"),
                supportsTodo: true,
                supportsPanelArtifacts: false
            )
            #expect(renderer == .fallbackCard)
        }
    }

    @Test func fileBackedKindsWithoutPathFallBackToCard() {
        for path in [nil, ""] as [String?] {
            for kind in [MobileSurfacePreview.Kind.filePreview, .markdown] {
                let renderer = MacSurfaceRenderer.resolve(
                    surface: surface(kind: kind, filePath: path),
                    supportsTodo: true,
                    supportsPanelArtifacts: true
                )
                #expect(renderer == .fallbackCard)
            }
        }
    }

    @Test func macRenderedKindsAlwaysUseTheCard() {
        let kinds: [MobileSurfacePreview.Kind] = [
            .terminal, .browser, .rightSidebarTool, .customSidebar, .agentSession,
            .project, .extensionBrowser, .cloudVMLoading, .other("simulator"),
        ]
        for kind in kinds {
            let renderer = MacSurfaceRenderer.resolve(
                surface: surface(kind: kind, filePath: "/tmp/demo", todo: todoSnapshot),
                supportsTodo: true,
                supportsPanelArtifacts: true
            )
            #expect(renderer == .fallbackCard)
        }
    }
}
