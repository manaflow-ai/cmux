import AppKit
public import CmuxNextDesign

// `browser.toolbarPosition`: the toolbar rows (toolbar, accessory bar, the
// pane's tab strip band) above the page, or mirrored below it. The find pill
// and the permission bar sit at the page's edge by the toolbar, and the
// omnibar's suggestions and the toolbar's menus open toward the page
// (`NSView.toolbarOpensUpward`).
extension BrowserChromeView: ToolbarEdgeHosting {
    func applyToolbarPosition() {
        toolbarEdge.activate(toolbarPosition)
        needsLayout = true
    }
}
