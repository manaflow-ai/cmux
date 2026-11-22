import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's profile menu tracks the pointer as an `NSMenu` does (Lawrence, 2026-11-17: "now mousedown drag
/// mouseup doesnt work like it does natively"): press the profile control, drag onto a row, release, and the row
/// runs. A plain click still opens the menu and leaves it open for a second click.
@MainActor @Suite(.serialized, .closesItsWindows) struct ProfileMenuPressDragTests {
    /// Records which rows ran.
    final class Recorder: NSObject {
        var picked: [String] = []
        @objc func pick(_ sender: NSMenuItem) { picked.append(sender.title) }
    }

    struct Setup {
        let h: SidebarBandHideTests.Harness
        let button: SidebarItemRowView
        let recorder: Recorder
    }

    func make() async throws -> Setup {
        let h = try await SidebarBandHideTests().make()
        h.window.orderFrontRegardless()
        h.model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        let recorder = Recorder()
        h.sidebar.profileMenuProvider = {
            let menu = NSMenu()
            for title in ["Settings…", "Help", "Sign Out"] {
                menu.addItem(withTitle: title, action: #selector(Recorder.pick(_:)), keyEquivalent: "").target = recorder
            }
            return menu
        }
        await h.until { h.sidebar.footerBand.profileControl?.view.showsAvatar == true }
        let button = try #require(h.sidebar.footerBand.profileControl?.view)
        button.layoutSubtreeIfNeeded()
        return Setup(h: h, button: button, recorder: recorder)
    }

    /// The glass menu panel on screen now, if any.
    static func menuPanel() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "cmux.glass-menu" && $0.isVisible && $0.alphaValue > 0 }
            ?? NSApp.windows.first { $0.identifier?.rawValue == "cmux.glass-menu" && $0.isVisible }
    }

    /// The center of the row titled `title` in the open menu, in screen coordinates.
    static func rowCenter(_ title: String, in panel: NSWindow) -> CGPoint? {
        guard let root = panel.contentView, let row = rows(in: root).first(where: { $0.titleLabel.stringValue == title }) else { return nil }
        let rect = panel.convertToScreen(row.convert(row.bounds, to: nil))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func rows(in view: NSView) -> [PopupRowView] {
        (view as? PopupRowView).map { [$0] } ?? view.subviews.flatMap(rows(in:))
    }

    static func event(_ type: NSEvent.EventType, at screen: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Press on the profile control, drag onto "Help", release: Help runs and the menu closes.
    @Test func pressDragReleaseOnARowRunsIt() async throws {
        let s = try await make()
        defer { s.h.sidebar.footerBand.popUpProfileMenu(NSMenu(), from: nil); s.h.tearDown() }
        let center = s.button.convert(CGPoint(x: s.button.bounds.midX, y: s.button.bounds.midY), to: nil)
        let down = try #require(Self.event(.leftMouseDown, at: s.h.window.convertPoint(toScreen: center), in: s.h.window))
        s.button.mouseDown(with: down)
        await s.h.until({ Self.menuPanel() != nil }, within: .seconds(10))
        let panel = try #require(Self.menuPanel(), "the press opened no menu")
        let help = try #require(Self.rowCenter("Help", in: panel))
        // The drag passes over Settings first, as a real drag would.
        let settings = try #require(Self.rowCenter("Settings…", in: panel))
        for point in [settings, help] {
            s.button.mouseDragged(with: try #require(Self.event(.leftMouseDragged, at: point, in: s.h.window)))
        }
        s.button.mouseUp(with: try #require(Self.event(.leftMouseUp, at: help, in: s.h.window)))
        await s.h.until({ !s.recorder.picked.isEmpty }, within: .seconds(10))
        #expect(s.recorder.picked == ["Help"], "releasing over Help ran \(s.recorder.picked)")
        await s.h.until({ Self.menuPanel() == nil }, within: .seconds(10))
        #expect(Self.menuPanel() == nil, "the menu stayed open after a row was picked by release")
    }

    /// A plain click (press and release on the control) opens the menu and leaves it open, as an `NSMenu`'s does;
    /// a click on a row then runs it.
    @Test func aClickOpensTheMenuAndAClickOnARowRunsIt() async throws {
        let s = try await make()
        defer { s.h.sidebar.footerBand.popUpProfileMenu(NSMenu(), from: nil); s.h.tearDown() }
        let center = s.h.window.convertPoint(toScreen: s.button.convert(CGPoint(x: s.button.bounds.midX, y: s.button.bounds.midY), to: nil))
        s.button.mouseDown(with: try #require(Self.event(.leftMouseDown, at: center, in: s.h.window)))
        await s.h.until({ Self.menuPanel() != nil }, within: .seconds(10))
        s.button.mouseUp(with: try #require(Self.event(.leftMouseUp, at: center, in: s.h.window)))
        await s.h.until({ false }, within: .milliseconds(100))
        let panel = try #require(Self.menuPanel(), "a click on the profile control left no menu open")
        #expect(s.recorder.picked.isEmpty)
        let root = try #require(panel.contentView)
        let row = try #require(Self.rows(in: root).first { $0.titleLabel.stringValue == "Sign Out" })
        row.onActivate?()
        await s.h.until({ !s.recorder.picked.isEmpty }, within: .seconds(10))
        #expect(s.recorder.picked == ["Sign Out"])
    }

    /// Press, drag off the control to empty space (not into the menu), release: the menu closes and nothing runs.
    @Test func releasingAwayFromTheMenuClosesItAndRunsNothing() async throws {
        let s = try await make()
        defer { s.h.sidebar.footerBand.popUpProfileMenu(NSMenu(), from: nil); s.h.tearDown() }
        let center = s.h.window.convertPoint(toScreen: s.button.convert(CGPoint(x: s.button.bounds.midX, y: s.button.bounds.midY), to: nil))
        s.button.mouseDown(with: try #require(Self.event(.leftMouseDown, at: center, in: s.h.window)))
        await s.h.until({ Self.menuPanel() != nil }, within: .seconds(10))
        let away = CGPoint(x: s.h.window.frame.maxX + 400, y: s.h.window.frame.maxY + 300)
        s.button.mouseDragged(with: try #require(Self.event(.leftMouseDragged, at: away, in: s.h.window)))
        s.button.mouseUp(with: try #require(Self.event(.leftMouseUp, at: away, in: s.h.window)))
        await s.h.until({ Self.menuPanel() == nil }, within: .seconds(10))
        #expect(Self.menuPanel() == nil, "releasing away from the menu left it open")
        await s.h.until({ false }, within: .milliseconds(100))
        #expect(s.recorder.picked.isEmpty)
    }
}
