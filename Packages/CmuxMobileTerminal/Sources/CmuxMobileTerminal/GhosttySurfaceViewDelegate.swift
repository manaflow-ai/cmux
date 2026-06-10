#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

@MainActor
public protocol GhosttySurfaceViewDelegate: AnyObject {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data)
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize)
    /// Forward a scroll gesture to the Mac's real surface. `lines` is signed
    /// (sign = direction), `col`/`row` is the grid cell under the finger (so
    /// alt-screen mouse-wheel reports at the right cell). Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int)
    /// Forward a tap to the Mac's real surface as a left click at the given grid
    /// cell, so TUIs with mouse reporting (lazygit/htop/fzf) receive the click.
    /// The Mac's libghostty self-gates: a normal screen treats it as a harmless
    /// empty selection. Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int)
    /// The user tapped the "customize" button at the end of the input-accessory
    /// bar; the host should present the toolbar shortcuts editor. Optional.
    func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView)
    /// Forward an image the user pasted from the system clipboard. The host
    /// uploads `data` to the Mac, which materializes a temp file and injects its
    /// path into the terminal so a running TUI (e.g. Claude Code) attaches it.
    /// `format` is a lowercase file-extension hint (e.g. `"png"`). Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String)
}

public extension GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {}
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {}
    func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView) {}
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {}
}

@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    var currentGridSize: TerminalGridSize { get }
    func processOutput(_ data: Data)
    func focusInput()
    /// Apply the daemon's authoritative rendering grid. Unconditional —
    /// implementations render at exactly cols × rows and letterbox any
    /// remaining container area. The daemon broadcasts this on every
    /// attach/resize/detach/open, plus inlined in RPC responses, so
    /// every attached device converges on the same grid.
    func applyViewSize(cols: Int, rows: Int)
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? { get set }
    func accessibilityRenderedTextForTesting() -> String?
    #endif
}

extension TerminalSurfaceHosting {
    func focusInput() {}
    func applyViewSize(cols _: Int, rows _: Int) {}
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? {
        get { nil }
        set {}
    }
    func accessibilityRenderedTextForTesting() -> String? { nil }
    #endif
}


#endif
