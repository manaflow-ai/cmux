import AppKit
@testable import CmuxTerminal

@MainActor
struct FakeTerminalSurfaceViewProvider: TerminalSurfaceViewProviding {
    let surfaceView: FakeTerminalSurfaceNativeView
    let paneHost: FakeTerminalSurfacePaneHost

    func makeSurfaceViews(
        initialFrame: NSRect,
        renderOwnership: TerminalSurfaceRenderOwnership
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        _ = initialFrame
        precondition(surfaceView.renderOwnership == renderOwnership)
        return (surfaceView, paneHost)
    }
}
