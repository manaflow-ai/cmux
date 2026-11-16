import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's bottom-left profile control (Leo and Lawrence 2026-10-20): the
/// avatar alone at any width, with no name and no chevron; the name shows on
/// hover and the full identity in its menu. Search and the spaces dots follow it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarProfileChipTests {
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
        model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
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

    @Test func aRoomyFooterShowsTheAvatarAlone() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        #expect(control.showsAvatar)
        #expect(control.titleFrame == .zero, "no name beside the avatar")
        #expect(control.icon.isHidden, "no chevron")
        let frame = h.frame(of: control)
        #expect(abs(frame.width - frame.height) < 0.5, "the avatar's square: \(frame)")
        #expect(control.themedToolTip?.hasPrefix("Default") == true, "the name shows on hover")
        // Search and the dots sit after the avatar.
        let search = h.frame(of: h.sidebar.searchButton)
        #expect(!h.sidebar.searchButton.isHidden && search.minX >= frame.maxX, "search \(search) after the avatar \(frame)")
    }

    /// Swift live mode's mark sits right after the avatar on its line, before Search, and the
    /// spaces dots start after it (Leo 2026-11-06: "at the bottom just to the right of the
    /// profile circle in the sidebar").
    @Test func theLiveModeBadgeFollowsTheAvatar() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let badge = LiveModeBadgeView()
        h.sidebar.liveModeBadge = badge
        h.settle()
        let avatar = h.frame(of: try #require(h.sidebar.footerBand.profileControl?.view))
        let mark = h.frame(of: badge)
        #expect(mark.width > 0 && mark.minX >= avatar.maxX && mark.minX - avatar.maxX <= Metrics.space2 + 0.5,
                "the mark \(mark) right after the avatar \(avatar)")
        #expect(abs(mark.midY - avatar.midY) < 1, "on the avatar's line")
        #expect(mark.maxX <= h.frame(of: h.sidebar.searchButton).minX, "before Search")
        #expect(h.frame(of: h.sidebar.profileBar).minX >= mark.maxX, "the dots start after the mark")
        h.sidebar.liveModeBadge = nil
        h.settle()
        #expect(badge.superview == nil)
    }

    /// App health's line moves nothing in the footer row when it comes and goes (Leo, 2026-11-11: "slow
    /// indicator on the bottom left is uselsss and layout shifts the space. it's bad"): the spaces strip, its
    /// dots and "+", the update button and Search keep their frames, and the line floats above the row at the
    /// avatar's leading edge. As a badge it sits on the avatar's corner, and moves nothing either.
    @Test func theHealthLineMovesNothingInTheFooterRow() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        h.sidebar.spacesPosition = .bottom
        h.sidebar.model.profiles = [SidebarProfile(id: ProfileKey("work"), name: "Work", color: .blue),
                                    SidebarProfile(id: ProfileKey("home"), name: "Home", color: .green)]
        h.sidebar.model.activeProfileID = ProfileKey("work")
        h.sidebar.showUpdateAvailable("Update Available")
        h.settle()
        let bar = h.sidebar.profileBar
        let row = { [h.frame(of: bar), h.frame(of: h.sidebar.updateAvailableButton), h.frame(of: h.sidebar.searchButton)] + bar.slotRects() }
        let atRest = row()
        let avatar = try #require(h.sidebar.footerBand.bandFirstRow?.frame)
        for long in [false, true] {
            let line = NSTextField(labelWithString: long ? String(repeating: "Session service isn’t responding ", count: 4) : "Agent chat isn’t responding")
            h.sidebar.healthIndicator = line
            h.settle()
            #expect(row() == atRest, "the row holds still with the line (long: \(long))")
            let frame = h.frame(of: line)
            #expect(frame.width > 0 && abs(frame.minX - avatar.minX) < 0.5, "at the avatar's leading edge: \(frame)")
            #expect(frame.maxY <= avatar.minY, "above the row: \(frame) over \(avatar)")
            #expect(frame.maxX <= h.sidebar.bounds.width, "inside the sidebar")
            h.sidebar.healthIndicator = nil
            h.settle()
            #expect(row() == atRest, "and still once it leaves")
        }
        let badge = Badge(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        h.sidebar.healthIndicator = badge
        h.settle()
        #expect(row() == atRest, "the badge moves nothing either")
        #expect(h.frame(of: badge).intersects(avatar), "on the avatar's corner: \(h.frame(of: badge)) \(avatar)")
        h.sidebar.healthIndicator = nil
    }

    /// App health's `dot` treatment, as the footer sees it.
    final class Badge: NSView, AvatarBadgePlacing {
        var sitsOnAvatar: Bool { true }
        override var fittingSize: NSSize { NSSize(width: 10, height: 10) }
    }

    /// Signed in, the avatar alone shows at rest; hovering it says the email (Leo 2026-10-21).
    @Test func theSignedInAvatarSaysTheEmailOnHover() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        h.sidebar.model.profileAvatar = .account(name: "Leo Li", email: "leo@cmux.com")
        for _ in 0..<20 {
            h.settle()
            if h.sidebar.footerBand.profileControl?.view.themedToolTip == "leo@cmux.com" { break }
            await Task.yield()
        }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        #expect(control.showsAvatar)
        #expect(control.titleFrame == .zero, "no email or name beside the avatar")
        #expect(control.themedToolTip == "leo@cmux.com")
        #expect(control.accessibilityLabel() == "Leo Li", "VoiceOver still hears the name")
    }

    /// The monogram is drawn on the theme accent, glazed, at any scale: a 1x and a 3x render
    /// both color the disc's center and leave its corners clear.
    @Test func theMonogramFillsItsCircleAtEveryScale() throws {
        let avatar = SidebarAvatar.account(name: "Leo Li", email: "leo@cmux.com")
        for scale in [1, 2, 3] {
            let side = 24 * scale
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: 24, height: 24)
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            ThemeScope.app.perform { SidebarAvatarView.draw(avatar, in: NSRect(x: 0, y: 0, width: 24, height: 24), strong: false) }
            NSGraphicsContext.restoreGraphicsState()
            let edge = (rep.colorAt(x: side / 2, y: side / 10)?.alphaComponent ?? 0)
            #expect(edge > 0.5, "@\(scale)x: the disc is filled near its top: \(edge)")
            #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.05, "@\(scale)x: the corner stays clear")
        }
    }

    @Test func aNarrowFooterKeepsTheAvatarAlone() async throws {
        let h = await make(width: 120)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        control.layoutSubtreeIfNeeded()
        #expect(control.showsAvatar)
        #expect(control.titleFrame == .zero, "no name where it does not fit")
        let frame = h.frame(of: control)
        #expect(abs(frame.width - frame.height) < 0.5, "the avatar's square: \(frame)")
    }

    @Test func theAvatarHoldsAFillWhileItsMenuIsOpen() async throws {
        let h = await make(width: 240)
        defer { h.window.close() }
        let control = try #require(h.sidebar.footerBand.profileControl?.view)
        #expect(control.fill == nil, "no fill at rest")
        control.showsMenu = true
        #expect(control.fill != nil, "the open menu's control shows a fill")
        control.showsMenu = false
        #expect(control.fill == nil, "the fill clears when the menu closes")
    }

    /// The initial's ink sits in the middle of the circle (Leo 2026-10-20: the "L" sat off
    /// center), drawn flipped in the footer and unflipped in the menu's image.
    @Test func theInitialIsCenteredInItsCircle() {
        let circle = NSRect(x: 4, y: 6, width: 20, height: 20)
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let ink = ("L" as NSString).boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics],
                                                 attributes: [.font: font])
        for flipped in [true, false] {
            let origin = SidebarAvatarView.initialOrigin("L", font: font, in: circle, flipped: flipped)
            #expect(abs(origin.x + ink.midX - circle.midX) < 0.01)
            let baseline = flipped ? origin.y + font.ascender : origin.y - font.descender
            let capCenter = flipped ? baseline - font.capHeight / 2 : baseline + font.capHeight / 2
            #expect(abs(capCenter - circle.midY) < 0.01, "flipped \(flipped): cap center \(capCenter)")
        }
        // The ink, not the advance: an "L" leans left inside its advance.
        let advance = ("L" as NSString).size(withAttributes: [.font: font]).width
        #expect(abs(SidebarAvatarView.initialOrigin("L", font: font, in: circle, flipped: true).x - (circle.midX - advance / 2)) > 0.1)
    }
}
