import AppKit
import CmuxNextDesign
import Testing

/// A pane's content as the app makes it: a root view with a content area, and the shown kind's view (a browser's
/// chrome) on top in that area. The layout asks the root for the surfaces of the pane's next commit
/// (`NSView.paneCommitSurfaces()`); a chrome that names its shown page takes part, so the frame that shows a zoom
/// shows the page at its new size. Before, only the root itself was asked, and no app content took part (Lawrence
/// 2026-11-20: a zoomed AWS console showed its old frame beside a white backdrop for two frames, then laid out again).
@MainActor @Suite struct PaneCommitSurfaceLookupTests {
    final class Surface: NSView, PaneCommitSurface {
        var changes: [CGSize] = []
        func commitWillResize(by change: CGSize, ready: @escaping @MainActor () -> Void) {
            changes.append(change)
            ready()
        }
    }

    final class Chrome: NSView, PaneCommitSurfaceHosting {
        let page = Surface(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var commitSurfaces: [any PaneCommitSurface] { [page] }
    }

    /// A root with a content area of 400 x 300 points, and `top` filling the area.
    static func content(top: NSView) -> (root: NSView, area: PaneContentAreaView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: root.bounds)
        root.addSubview(area)
        top.frame = area.bounds
        area.addSubview(top)
        return (root, area)
    }

    @Test func aChromeOnTopOfThePanesContentAreaNamesItsPageToTheCommit() {
        let chrome = Chrome()
        let (root, _) = Self.content(top: chrome)
        let surfaces = root.paneCommitSurfaces()
        #expect(surfaces.count == 1 && surfaces.first === chrome.page, "the pane's commit finds \(surfaces), not the chrome's page")
    }

    @Test func aSurfaceOnTopOfThePanesContentAreaTakesPart() {
        let surface = Surface()
        let (root, _) = Self.content(top: surface)
        let surfaces = root.paneCommitSurfaces()
        #expect(surfaces.count == 1 && surfaces.first === surface, "the pane's commit finds \(surfaces), not the surface on top")
    }

    /// Only the shown top view takes part: a chrome under another view that fills the area, a hidden chrome, and a
    /// hidden root take none.
    @Test func aCoveredOrHiddenChromeTakesNoPart() {
        let chrome = Chrome()
        let (root, area) = Self.content(top: chrome)
        let cover = NSView(frame: area.bounds)
        area.addSubview(cover)
        #expect(root.paneCommitSurfaces().isEmpty, "a covered chrome's page takes part in its pane's commit")
        cover.removeFromSuperview()
        chrome.isHidden = true
        #expect(root.paneCommitSurfaces().isEmpty, "a hidden chrome's page takes part in its pane's commit")
        chrome.isHidden = false
        root.isHidden = true
        #expect(root.paneCommitSurfaces().isEmpty, "a hidden pane content's page takes part in its pane's commit")
    }
}
