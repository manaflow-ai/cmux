import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 (sidebar-footer.png): the account row and the Search button sat too high and off
/// each other's line, the magnifying glass floating above the avatar's center. The footer is one
/// line: the account chip, its avatar and the Search button share one center, and the line's
/// taller control ends `SidebarStyle.bottomInset` (#22663's 8 pt) above the window's bottom edge,
/// at every density. Leo 2026-10-21: the avatar is as big as its square allows and the Search
/// button sits right after it, its lens on the avatar's center.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFooterAlignmentTests {
    struct Harness {
        let sidebar: SidebarView
        let window: NSWindow

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        func frame(of view: NSView) -> NSRect { sidebar.convert(view.bounds, from: view) }
    }

    private func make(width: CGFloat) async -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profileAvatar = .account(name: "leo@cmux.com")
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let harness = Harness(sidebar: sidebar, window: window)
        for _ in 0..<20 {
            harness.settle()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        harness.settle()
        return harness
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let density: SidebarDensity
        let width: CGFloat
        var testDescription: String { "\(density) \(Int(width))" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [Case(density: density, width: 240), Case(density: density, width: 120)]
    }

    @Test(arguments: cases) func theAccountAndSearchShareOneLineAboveTheBottomMargin(_ c: Case) async throws {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = c.density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let h = await make(width: c.width)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        let chip = h.frame(of: control)
        let circle = h.sidebar.convert(control.avatarView.circleFrame, from: control.avatarView)
        let search = h.frame(of: h.sidebar.searchButton)
        try #require(!h.sidebar.searchButton.isHidden, "the search button shows")

        // One center line: the chip, its avatar and the magnifying glass's lens, which rides a
        // device pixel above the Search button's middle (Leo 2026-10-21: "move the magnifying glass
        // a bit lower").
        let lens = search.midY - h.sidebar.footerBand.searchLensDrop
        #expect(h.sidebar.footerBand.searchLensDrop > 0, "the button sits under the line by its lens")
        #expect(abs(lens - circle.midY) <= 0.25, "search's lens \(lens) off the avatar's center \(circle)")
        #expect(abs(circle.midY - chip.midY) <= 0.25, "the avatar \(circle) off the chip's center \(chip)")
        if control.titleFrame.height > 0 {
            let title = h.sidebar.convert(control.titleFrame, from: control)
            #expect(abs(title.midY - circle.midY) <= 0.5, "name \(title) off the avatar's center \(circle)")
        }

        // The avatar is the sidebar's icon box (16 pt at compact), as before #23757 (Lawrence
        // 2026-10-21: "bottom footer thing too big, revert to old icon sizes"), centered in its
        // square, and the Search button sits flush against that square: the two controls' own
        // insets are the gap, as a toolbar's buttons.
        #expect(abs(circle.width - SidebarStyle.iconBox) <= 0.25, "avatar \(circle) is not the icon box \(SidebarStyle.iconBox)")
        #expect(abs(circle.midX - chip.midX) <= 0.25, "avatar \(circle) off its square's center \(chip)")
        #expect(abs(search.minX - chip.maxX) <= 0.25, "search \(search) flush after the avatar's square \(chip)")

        // The line's taller control ends exactly the bottom margin above the window's edge (flipped: maxY is the bottom).
        let lineBottom = max(search.maxY, chip.maxY)
        let floor = h.sidebar.bounds.maxY - SidebarStyle.bottomInset
        #expect(abs(lineBottom - floor) <= 0.25, "the footer line ends at \(lineBottom), the margin at \(floor)")
    }

    /// Compact footer is one slim row: the pinned line is the sidebar row's height with no extra
    /// padding under it (the Search button is the row's height too), so the whole bottom stack
    /// from the list's edge to the window's bottom is the row plus the margin.
    @Test(arguments: cases) func theFooterIsOneRowWithNoPaddingUnderIt(_ c: Case) async throws {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = c.density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let h = await make(width: c.width)
        defer { h.window.close() }
        _ = try #require(h.sidebar.footerBand.profileControl?.view)
        let line = h.sidebar.footerRegion.frame
        let rowHeight = Metrics.sidebarRowHeight
        // Half a point of slack for the lens drop (one device pixel).
        #expect(line.height <= rowHeight + 0.5, "footer line \(line.height) pt is taller than the row \(rowHeight) pt")
        let reserve = h.sidebar.bounds.maxY - line.minY
        // The margin is the 4 pt grid step (Metrics.space2 at compact), was 8 pt (space4).
        #expect(SidebarStyle.bottomInset == Metrics.space2, "margin \(SidebarStyle.bottomInset) pt is not the 4 pt step \(Metrics.space2)")
        #expect(reserve <= rowHeight + Metrics.space2 + 0.5, "bottom reserve \(reserve) pt exceeds row + 4 pt margin")
    }
}
