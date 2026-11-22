import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// R109: the sidebar sits on either window edge (`sidebar.side`), and the
/// spaces dots sit at its top or bottom (`sidebar.spacesPosition`).
@MainActor @Suite struct SidebarPlacementTests {
    /// A shown container pinned to `side`'s edge of an 800-point parent.
    private func container(_ side: SidebarSide) -> (SidebarContainerView, NSView) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let model = SidebarModel()
        model.width = 260
        let view = SidebarContainerView(model: model)
        parent.addSubview(view)
        let edge = side == .left ? view.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            : view.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        NSLayoutConstraint.activate([edge, view.topAnchor.constraint(equalTo: parent.topAnchor),
                                     view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
        view.side = side
        parent.layoutSubtreeIfNeeded()
        return (view, parent)
    }

    @Test(arguments: [SidebarSide.left, .right])
    func theResizeEdgeFacesTheContent(_ side: SidebarSide) {
        let (view, _) = container(side)
        let edge = side == .left ? view.bounds.maxX : view.bounds.minX
        #expect(abs(view.handle.frame.midX - edge) <= 1, "on the edge, within layout rounding")
        let list = view.sidebarView.convert(view.sidebarView.bounds, to: view)
        #expect(abs(list.minX) < 0.5 && abs(list.width - 260) < 0.5)
    }

    @Test(arguments: [SidebarSide.left, .right])
    func draggingTheEdgeTowardTheContentWidensTheSidebar(_ side: SidebarSide) {
        let (view, _) = container(side)
        view.handle.onDrag?(.began)
        view.handle.onDrag?(.changed(side == .left ? 40 : -40))
        view.handle.onDrag?(.ended)
        #expect(view.model.width == 300)
    }

    private func sidebar(spaces position: SpacesPosition) -> SidebarView {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("a"), name: "Default"), SidebarProfile(id: ProfileKey("b"), name: "Work")]
        model.activeProfileID = ProfileKey("a")
        let view = SidebarView(model: model)
        view.spacesPosition = position
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    @Test func spacesAtTheTopSitUnderTheTitlebarRowAboveTheTopSections() {
        let view = sidebar(spaces: .top)
        let dots = view.profileBar.convert(view.profileBar.bounds, to: view)
        #expect(!view.profileBar.isHidden && dots.height > 0)
        #expect(abs(dots.minY - view.titlebarHeight) < 0.5, "the dots start under the titlebar row")
        #expect(view.aboveFade.frame.minY >= dots.maxY - 0.5, "the top sections start under the dots")
        #expect(abs(view.footerRegion.frame.maxY - view.bounds.maxY) < 0.5, "the footer section stays at the bottom")
        #expect(view.footer.frame.height == 0 || view.footer.frame.maxY <= view.belowFade.frame.minY + 0.5)
    }

    /// Amendment 3: at the bottom the dots share the footer band's row.
    @Test func spacesAtTheBottomShareTheFooterBandRow() {
        let view = sidebar(spaces: .bottom)
        let dots = view.profileBar.convert(view.profileBar.bounds, to: view)
        let band = view.footerRegion.frame
        #expect(dots.minY >= band.minY - 0.5 && dots.maxY <= band.maxY + 0.5 && dots.height > 0, "\(dots) in \(band)")
    }

    /// `sidebar.spacesVisibility` always (cx-5k3r) keeps the strip shown at rest.
    @Test func spacesAlwaysVisibleShowAtRest() {
        let view = sidebar(spaces: .bottom)
        #expect(view.profileBar.alphaValue == 0, "the default shows them on hover only")
        view.spacesVisibility = .always
        #expect(view.profileBar.alphaValue == 1)
        view.spacesVisibility = .hover
        #expect(view.profileBar.alphaValue == 0)
    }
}
