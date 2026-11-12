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
/// `cmux-ci run --artifact`. `renderCheckColumnGallery` draws the checked team row's variants
/// (`Check`) into `profile-menu-check-gallery.tar`.
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

    /// The checked team row's mark (Leo, 2026-11-10, on the menu with the active team checked:
    /// "this is too big at the left i think", "at the very least it's awkward looking"):
    /// `before`, AppKit's checkmark column stacked left of the icon column (every row's icon at 22,
    /// its text at 42); `slot`, the shipped one leading column, the check in the checked row's icon
    /// slot (`NSMenu.fitStateColumn()`); `badge`, every team keeps its icon and the active one's
    /// carries a small check; `bare`, the team rows draw no icon, so only the active one shows a
    /// mark, as a macOS menu without icons draws its checked row.
    enum Check: String, CaseIterable { case before, slot, badge, bare }

    /// The account menu as Leo's shot shows it: who it is, then three teams, the first checked.
    static func checkMenu(_ check: Check, dark: Bool, services: AppServices) -> NSMenu {
        let builder = ProfileMenuBuilder(registry: services.registry)
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"), avatar: avatar(), chiefPetShown: true)
        builder.addAccountRows(to: menu, who: ["leo@example.com"], avatar: avatar())
        let teams: [(String, String, String)] = [("cmux", "Team", "person.2"), ("leo@example.com's Team", "Team", "person.2"),
                                                 ("Personal", "leo@example.com", "person")]
        let after = (menu.items.firstIndex { $0.identifier?.rawValue == "profileMenu.person" } ?? 0) + 1
        var rows: [NSMenuItem] = [.separator()]
        for (index, team) in teams.enumerated() {
            let row = NSMenuItem(title: team.0, action: #selector(TeamTarget.pick(_:)), keyEquivalent: "")
            row.target = TeamTarget.shared
            if #available(macOS 14.4, *) { row.subtitle = team.1 }
            row.state = index == 0 ? .on : .off
            row.identifier = NSUserInterfaceItemIdentifier("profileMenu.team")
            switch check {
            case .bare: row.image = nil
            case .badge: row.image = index == 0 ? badged(team.2) : NSImage.menuSymbol(team.2)
            case .before, .slot: row.image = NSImage.menuSymbol(team.2)
            }
            if check == .badge { row.state = .off }
            rows.append(row)
        }
        for (offset, row) in rows.enumerated() { menu.insertItem(row, at: after + offset) }
        if check == .bare {
            // The team section's rows keep the text column with an empty slot (as `keepOneTextColumn` does).
            for row in rows where !row.isSeparatorItem && row.state == .off { row.image = NSImage(size: NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)) }
        }
        menu.themeRows(in: ThemeScope(level: .room))
        if check == .before {
            // What feat-cmux-next drew: the checked row keeps its icon and AppKit's checkmark column opens.
            menu.items.filter { MenuStateMark.markedState($0) != nil }.forEach {
                $0.image = NSImage.menuSymbol("person.2")?.fittedToMenuIconBox()
                $0.state = .on
            }
            menu.showsStateColumn = true
        }
        menu.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return menu
    }

    /// The team rows' target, so AppKit draws them enabled as the app's bound rows are.
    @MainActor final class TeamTarget: NSObject {
        static let shared = TeamTarget()
        @objc func pick(_ sender: Any?) {}
    }

    static func avatar() -> NSImage {
        NSImage(size: NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    /// `symbol` with a small filled check at its lower right, in the grid's icon box.
    static func badged(_ symbol: String) -> NSImage? {
        guard let icon = NSImage.menuSymbol(symbol)?.fittedToMenuIconBox(),
              let check = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Checked") else { return nil }
        let side = MenuMetrics.iconSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 8, y: rect.minY, width: 8, height: 8)
            NSColor.controlAccentColor.set()
            check.draw(in: badge)
            return true
        }
        image.isTemplate = false
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderCheckColumnGallery() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let services = ProfileMenuColumnTests.services()
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "profile-menu-check-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var geometry: [String] = []
        var drawn = 0
        for check in Check.allCases {
            for dark in [true, false] {
                let name = "\(check.rawValue)-\(dark ? "dark" : "light")"
                let menu = Self.checkMenu(check, dark: dark, services: services)
                let shot = try Self.capture(menu)
                geometry.append("\(name): width \(menu.size.width), state column \(menu.showsStateColumn), \(shot.note)")
                geometry += shot.titles.map { "  \($0.0): text x \($0.1)" }
                if let image = shot.image {
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png"))
                    drawn += 1
                }
            }
        }
        try geometry.joined(separator: "\n").write(to: out.appending(path: "geometry.txt"), atomically: true, encoding: .utf8)
        print("profile-menu-check-gallery\n" + geometry.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "profile-menu-check-gallery.tar", "profile-menu-check-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        #expect(drawn > 0, "no menu window was drawn: \(geometry)")
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
