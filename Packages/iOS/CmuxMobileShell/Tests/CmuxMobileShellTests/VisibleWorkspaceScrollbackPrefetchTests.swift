import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func cachedVisibleWorkspaceScrollbackIsFirstOutputOnMount() async throws {
    let surfaceID = "terminal-visible-prefetch"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 42,
        columns: 4,
        rows: 1,
        rowSpans: [],
        scrollbackRows: 8,
        scrollbackSpans: []
    )
    let store = MobileShellComposite.preview()
    store.visibleWorkspaceScrollbackPrefetchesBySurfaceID[surfaceID] =
        VisibleWorkspaceScrollbackPrefetch(
            delivery: TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: true,
                viewportPolicy: frame.mobileViewportPolicy
            ),
            fetchedAt: Date()
        )

    var output = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let first = try #require(await output.next())

    #expect(first.sourceRenderGridFrame?.stateSeq == 42)
    #expect(first.sourceRenderGridFrame?.scrollbackRows == 8)
    #expect(!store.visibleWorkspaceScrollbackPrefetchesBySurfaceID.keys.contains(surfaceID))
}
