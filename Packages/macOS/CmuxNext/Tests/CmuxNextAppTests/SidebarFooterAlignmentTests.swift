import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20 (sidebar-footer.png): the account row and the Search button sat too high and off
/// each other's line, the magnifying glass floating above the avatar's center. The footer is one
/// line: the account chip, its avatar and the Search button share one center, and the line's
/// taller control ends `SidebarStyle.bottomInset` (#22663's 8 pt) above the window's bottom edge,
/// at every density.
@MainActor @Suite(.serialized) struct SidebarFooterAlignmentTests {
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

        // One center line: the chip, its avatar and the Search button.
        #expect(abs(search.midY - circle.midY) <= 0.25, "search \(search) off the avatar's center \(circle)")
        #expect(abs(search.midY - chip.midY) <= 0.25, "search \(search) off the chip's center \(chip)")
        if control.titleFrame.height > 0 {
            let title = h.sidebar.convert(control.titleFrame, from: control)
            #expect(abs(title.midY - circle.midY) <= 0.5, "name \(title) off the avatar's center \(circle)")
        }

        // The line's taller control ends exactly the bottom margin above the window's edge (flipped: maxY is the bottom).
        let lineBottom = max(search.maxY, chip.maxY)
        let floor = h.sidebar.bounds.maxY - SidebarStyle.bottomInset
        #expect(abs(lineBottom - floor) <= 0.25, "the footer line ends at \(lineBottom), the margin at \(floor)")
    }
}
