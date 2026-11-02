import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the sidebar footer's profile menu as AppKit draws it, opened for real, light and dark
/// (grid.md 5.3, one text column; Leo 2026-10-22: "left alignment on the profile settings
/// dropdown/pop i think is similar"). Variants of the account header: `text` (its name and email
/// on the rows' text column), `lead` (on the icon column, a section header) and `avatar` (the
/// account's picture in the icon column). `CMUX_TEST_REQUIRE_GUI=1`; writes
/// `profile-menu-gallery.tar` (PNGs and `geometry.txt`, each title's measured x) for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAProfileMenuGalleryTests {
    enum Header: String, CaseIterable { case text, lead, avatar }

    static func menu(header: Header, dark: Bool, services: AppServices) -> NSMenu {
        let menu = ProfileMenuColumnTests.profileMenu(signedIn: true, services: services)
        let headers = menu.items.filter { !$0.isSeparatorItem && $0.submenu == nil && $0.action == nil }
        switch header {
        case .text: break
        case .lead: headers.forEach { $0.image = nil }
        case .avatar:
            let picture = NSImage(size: NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize), flipped: false) { rect in
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            headers.forEach { $0.image = NSImage(size: picture.size) }
            headers.first?.image = picture
        }
        menu.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return menu
    }

    /// Every view under `view`.
    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// Draws the open menu's window and reads where each title starts, from a timer that fires
    /// while the menu tracks, then closes the menu.
    @MainActor final class Capture: NSObject {
        let menu: NSMenu
        let before: Set<ObjectIdentifier>
        var image: CGImage?
        var titles: [(String, CGFloat)] = []
        var note = "no menu window"

        init(_ menu: NSMenu) {
            self.menu = menu
            before = Set(NSApp.windows.map(ObjectIdentifier.init))
        }

        @objc func fire(_ timer: Timer) {
            defer { menu.cancelTrackingWithoutAnimation() }
            let windows = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            note = "windows: " + windows.map { String(describing: type(of: $0)) }.joined(separator: ",")
            guard let window = windows.max(by: { $0.frame.height < $1.frame.height }),
                  let root = window.contentView?.superview ?? window.contentView else { return }
            root.layoutSubtreeIfNeeded()
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                image = rep.cgImage
            }
            let wanted = Set(menu.items.map(\.title))
            for view in AAProfileMenuGalleryTests.all(root) {
                guard let field = view as? NSTextField, wanted.contains(field.stringValue) else { continue }
                let rect = field.convert(field.bounds, to: root)
                let inset = field.cell?.titleRect(forBounds: field.bounds).minX ?? 0
                titles.append((field.stringValue, rect.minX + inset))
            }
        }
    }

    /// Opens `menu` from a view in an on-screen window (AppKit positions a pop-up on its view's
    /// screen) and captures it while it tracks.
    static func capture(_ menu: NSMenu) throws -> Capture {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first, "no screen: the gallery needs a GUI session")
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 80, width: 40, height: 40)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let anchor = try #require(window.contentView)
        let capture = Capture(menu)
        let timer = Timer(timeInterval: 0.6, target: capture, selector: #selector(Capture.fire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
        timer.invalidate()
        return capture
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let services = ProfileMenuColumnTests.services()
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "profile-menu-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var geometry: [String] = []
        var drawn = 0
        for header in Header.allCases {
            for dark in [false, true] {
                let name = "\(header.rawValue)-\(dark ? "dark" : "light")"
                let shot = try Self.capture(Self.menu(header: header, dark: dark, services: services))
                geometry.append("\(name): \(shot.note)")
                geometry += shot.titles.map { "  \($0.0): text x \($0.1)" }
                if let image = shot.image {
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png"))
                    drawn += 1
                }
            }
        }
        try geometry.joined(separator: "\n").write(to: out.appending(path: "geometry.txt"), atomically: true, encoding: .utf8)
        print("profile-menu-gallery\n" + geometry.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "profile-menu-gallery.tar", "profile-menu-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        #expect(drawn > 0, "no menu window was drawn: \(geometry)")
    }
}
