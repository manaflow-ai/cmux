import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-13 (msg 31502), on a full-width hairline under the docked Home's search, filter and compose
/// buttons: "make sure to fix this weird horizontal line". It is the tab row's divider: the Home draws its tools in its
/// pane's tab row (``PaneTabRowSharing``) and its content fills the pane from the top, so a line under the strip cuts
/// through its header. The divider leaves such a pane out (``TabStripView/meetsToolbar``), as it leaves out a browser
/// whose omnibar meets its tabs (`TabRowDividerOverToolbarTests`), at every density.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabRowSharerNoDividerTests {
    /// Content that draws `need` points of tools in the tab row, as the docked Home does.
    final class RowSharer: NSView, PaneTabRowSharing {
        let need: CGFloat
        private var shared: CGFloat = 0
        private var offeredOnce = false
        var onTabRowToolsChange: (() -> Void)?
        init(need: CGFloat) {
            self.need = need
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var tabRowToolsWidth: CGFloat? { shared }
        var tabRowToolsNeed: CGFloat? { shared > 0 || offeredOnce ? need : nil }
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            if height > 0 { offeredOnce = true }
            let next = height > 0 ? need : 0
            guard next != shared else { return }
            shared = next
            onTabRowToolsChange?()
        }
    }

    private func pane(showing content: NSView, in window: NSWindow) -> PaneContentView {
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "t0", kind: nil, paneKinds: [])
        pane.toolbar = toolbar
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView?.addSubview(pane)
        _ = pane.show(content)
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
        return pane
    }

    @Test(arguments: DensityPreset.allCases)
    func aPaneWhoseContentSharesTheTabRowHasNoDivider(_ density: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = density.tokens
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }

        let home = pane(showing: RowSharer(need: 120), in: window)
        #expect(!home.stripView.isHidden, "the pane shows its strip at \(density)")
        #expect(home.stripView.meetsToolbar, "no tab row divider through a header that shares the tab row at \(density)")

        // Content that starts under the strip (a terminal) keeps the divider.
        let terminal = pane(showing: NSView(), in: window)
        #expect(!terminal.stripView.meetsToolbar, "a terminal keeps the tab row's divider at \(density)")
    }
}
