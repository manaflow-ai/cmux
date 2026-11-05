import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Show Sidebar Controls Only on Hover (`sidebar.controlsOnHover`, Lawrence 2026-10-27 message 14242: "there should be a
/// minimal mode such that it will only show when the mouse is over the sidebar"); named apart from
/// Minimal Mode (`sidebar.minimal`, compact rows), which it stacks with. Off by default: the
/// New Workspace button, the spaces strip, the profile control and the Search button always show. On,
/// they hide until the pointer is over the sidebar, then fade in where they already sit (no layout
/// shift), at once under Reduce Motion. Cmd+Shift+P, the CLI and MCP turn it on and off.
@MainActor @Suite(.serialized) struct SidebarControlsOnHoverTests {
    // MARK: The rule

    @Test func byDefaultEveryControlShowsWithThePointerAway() {
        let rest = SidebarChromeReveal(revealed: false, minimalMode: .off, controlsOnHover: false, spacesVisibility: .hover)
        #expect(rest.newButton == 1)
        #expect(rest.spaces == 1)
        #expect(rest.footer == 1)
        #expect(rest.topBand == 1 && rest.bottomBand == 1)
    }

    @Test func controlsOnHoverHidesEveryControlUntilThePointerIsOver() {
        let rest = SidebarChromeReveal(revealed: false, minimalMode: .off, controlsOnHover: true, spacesVisibility: .hover)
        #expect(rest.newButton == 0)
        #expect(rest.spaces == 0)
        #expect(rest.footer == 0)
        let hovered = SidebarChromeReveal(revealed: true, minimalMode: .off, controlsOnHover: true, spacesVisibility: .hover)
        #expect(hovered.newButton == 1 && hovered.spaces == 1 && hovered.footer == 1)
    }

    /// `sidebar.spacesVisibility` Always pins the strip, controls on hover or not.
    @Test func spacesSetToAlwaysStayWithControlsOnHover() {
        let rest = SidebarChromeReveal(revealed: false, minimalMode: .off, controlsOnHover: true, spacesVisibility: .always)
        #expect(rest.spaces == 1)
        #expect(rest.newButton == 0)
    }

    /// The older Hide Bands Until Hover (`sidebar.minimalMode`) keeps hiding its bands, footer included.
    @Test func hideBandsUntilHoverStillHidesItsBands() {
        let rest = SidebarChromeReveal(revealed: false, minimalMode: .both, controlsOnHover: false, spacesVisibility: .hover)
        #expect(rest.topBand == 0 && rest.bottomBand == 0 && rest.footer == 0)
        #expect(rest.newButton == 1)
    }

    // MARK: The sidebar

    @Test func theSidebarShowsItsControlsAtRestByDefault() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        h.sidebar.setChromeRevealed(true)
        h.sidebar.setChromeRevealed(false)
        await h.until { h.sidebar.newButton.alphaValue == 1 && h.sidebar.searchButton.alphaValue == 1 }
        #expect(h.sidebar.newButton.alphaValue == 1)
        #expect(h.sidebar.searchButton.alphaValue == 1)
        #expect(h.sidebar.footerRegion.alphaValue == 1)
        #expect(!h.sidebar.profileBar.isHidden && h.sidebar.profileBar.alphaValue == 1)
    }

    @Test func controlsOnHoverFadesTheControlsInPlace() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"controlsOnHover":true}}"#)
        defer { h.tearDown() }
        h.sidebar.setChromeRevealed(false)
        await h.until { h.sidebar.newButton.alphaValue == 0 && h.sidebar.searchButton.alphaValue == 0 }
        let views: [NSView] = [h.sidebar.newButton, h.sidebar.searchButton, h.sidebar.footerRegion, h.sidebar.profileBar]
        #expect(views.allSatisfy { $0.alphaValue == 0 }, "\(views.map(\.alphaValue))")
        // A fade, never a hide: VoiceOver still reaches them, and nothing moves when they show.
        #expect(views.allSatisfy { !$0.isHidden || $0 === h.sidebar.profileBar })
        let before = views.map { h.sidebar.convert($0.bounds, from: $0) }
        let listBefore = h.sidebar.edgeFade.frame

        // Reduce Motion: the controls show at once, no fade to wait for.
        h.sidebar.setChromeRevealed(true)
        #expect(views.allSatisfy { $0.alphaValue == 1 }, "\(views.map(\.alphaValue))")
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(views.map { h.sidebar.convert($0.bounds, from: $0) } == before, "no layout shift")
        #expect(h.sidebar.edgeFade.frame == listBefore, "the list keeps its frame")

        h.sidebar.setChromeRevealed(false)
        #expect(views.allSatisfy { $0.alphaValue == 0 })
    }

    /// Minimal Mode (`sidebar.minimal`, compact rows) and controls on hover stack: the rows stay
    /// compact, the controls fade with the pointer, and the footer's avatar, Search button and
    /// spaces strip never overlap.
    @Test func controlsOnHoverStacksWithMinimalMode() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true,"controlsOnHover":true}}"#)
        defer { h.tearDown() }
        h.model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        await h.until { h.sidebar.footerBand.profileControl != nil && h.model.minimal }
        #expect(h.model.minimal, "Minimal Mode's compact rows stay on")
        h.sidebar.setChromeRevealed(false)
        #expect(h.sidebar.newButton.alphaValue == 0 && h.sidebar.searchButton.alphaValue == 0)
        h.sidebar.setChromeRevealed(true)
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(h.sidebar.newButton.alphaValue == 1 && h.sidebar.searchButton.alphaValue == 1)
        let search = h.sidebar.convert(h.sidebar.searchButton.bounds, from: h.sidebar.searchButton)
        let avatar = try #require(h.sidebar.footerBand.profileControl?.view)
        let avatarFrame = h.sidebar.convert(avatar.bounds, from: avatar)
        #expect(!search.intersects(avatarFrame), "search \(search) over avatar \(avatarFrame)")
        #expect(search.maxX <= h.sidebar.bounds.maxX && search.maxY <= h.sidebar.bounds.maxY, "search \(search) in \(h.sidebar.bounds)")
        if !h.sidebar.profileBar.isHidden {
            let dots = h.sidebar.convert(h.sidebar.profileBar.bounds, from: h.sidebar.profileBar)
            #expect(dots.maxX <= search.minX + 0.5, "dots \(dots) end before search \(search)")
            #expect(dots.minX >= avatarFrame.maxX - 0.5, "dots \(dots) start after avatar \(avatarFrame)")
        }
    }

    @Test func thePaletteCommandsTurnControlsOnHoverOnAndOff() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        h.sidebar.setChromeRevealed(false)
        _ = h.services.registry.perform("sidebar.controlsOnHover.on")
        await h.until { h.saved("controlsOnHover") == true && h.sidebar.newButton.alphaValue == 0 }
        #expect(h.saved("controlsOnHover") == true)
        #expect(h.sidebar.newButton.alphaValue == 0)

        _ = h.services.registry.perform("sidebar.controlsOnHover.off")
        await h.until { h.saved("controlsOnHover") == false && h.sidebar.newButton.alphaValue == 1 }
        #expect(h.saved("controlsOnHover") == false)
        #expect(h.sidebar.newButton.alphaValue == 1)
    }
}
