import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The space menu's colors (Leo 2026-11-11: "this colour selection for spaces is wack"). Before: Color was a submenu of
/// nine template rows (every swatch the same white dot) with Set Space Theme and Reset Space Theme nested inside it, and
/// the footer's dots were mixed toward the strip and dimmed to 70%. Now: the menu opens with the space's name and one row of real swatches
/// (the current one ringed, No Color first), Set Space Theme and Reset Space Theme are rows of their own, and a dot draws
/// the color its swatch draws, at full strength.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASpaceColorMenuGalleryTests {
    static let target = ActionTargetRef(kind: .profile, id: "work")

    /// A registry with the space menu's actions bound, as the app binds them.
    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        let ids: [ActionID] = ["space.rename", "space.setColor", "space.clearColor", "space.setTheme", "space.clearTheme"]
            + GroupColor.allCases.map { ActionID(rawValue: "space.color.\($0.rawValue)") }
        for id in ids { registry.bind(id, invoke: { _ in }) }
        return registry
    }

    static func spaceMenu(color: GroupColor?) -> NSMenu {
        let registry = registry(), menu = registry.makeContextMenu(for: .profile, target: target)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "Work", rename: "space.rename",
                                   current: color, noColor: color == nil)
        return menu
    }

    /// Every action a menu row runs, the row's own or its submenu's.
    static func runs(_ item: NSMenuItem) -> [ActionID] {
        [ActionRegistry.menuRun(of: item)?.id].compactMap { $0 } + (item.submenu?.items.compactMap { ActionRegistry.menuRun(of: $0)?.id } ?? [])
    }

    @Test func theSpaceMenuOpensWithItsSwatchesAndItsThemeRowsStandAlone() throws {
        let menu = Self.spaceMenu(color: .yellow)
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView, "the space menu opens with the name and swatches")
        let strip = try #require(header.strip)
        #expect(strip.current == .yellow, "the space's color is ringed")
        #expect(Set(strip.colors.compactMap { $0 }) == Set(GroupColor.allCases), "a swatch per color")
        #expect(strip.clearChoice != nil, "No Color comes first")
        for item in menu.items where item.submenu != nil {
            let runs = Self.runs(item)
            #expect(!(item.submenu?.items.contains { MenuIdentityHeader.color(of: $0) != nil } ?? false), "\(item.title) still lists colors")
            #expect(!(runs.contains("space.clearTheme") && runs.contains { $0.rawValue.hasPrefix("space.color") }), "a theme row sits in a color list")
        }
        #expect(menu.items.contains { ActionRegistry.menuRun(of: $0)?.id == "space.clearTheme" }, "Reset Space Theme is a row of the space menu")
        #expect(!menu.items.contains { ActionRegistry.menuRun(of: $0)?.id == "space.rename" }, "Rename Space… is the name field")
    }

    @Test func aSpaceWithNoColorRingsNoColor() throws {
        let strip = try #require((Self.spaceMenu(color: nil).items.first?.view as? MenuIdentityHeaderView)?.strip)
        #expect(strip.current == nil && strip.clearIsCurrent)
    }

    @Test func aDotDrawsItsSwatchColor() {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("a"), name: "A", color: .yellow), SidebarProfile(id: ProfileKey("b"), name: "B", color: .red)]
        model.activeProfileID = model.profiles.first?.id
        let bar = ProfileBarView(model: model)
        for profile in model.profiles {
            for active in [true, false] {
                let drawn = bar.profileColor(profile, active: active).usingColorSpace(.sRGB)
                let swatch = profile.color?.markColor.usingColorSpace(.sRGB)
                #expect(drawn == swatch, "\(profile.name) (current \(active)) draws \(String(describing: drawn)), not its swatch \(String(describing: swatch))")
                #expect(ProfileBarView.dotAlpha(profile, active: active, hovered: false) == 1, "\(profile.name)'s dot is dimmed")
            }
        }
    }

    /// The footer's dots: four spaces (none, yellow, red, green; the first current), before (mixed toward the strip) and now.
    static func dots(dark: Bool, before: Bool) throws -> CGImage {
        try AAWorkspaceNoColorGalleryTests.draw(width: 160, height: 32, dark: dark) { root, scope in
            let model = SidebarModel()
            model.profiles = [SidebarProfile(id: ProfileKey("d"), name: "Default"), SidebarProfile(id: ProfileKey("y"), name: "Work", color: .yellow),
                              SidebarProfile(id: ProfileKey("r"), name: "Ops", color: .red), SidebarProfile(id: ProfileKey("g"), name: "Home", color: .green)]
            model.activeProfileID = model.profiles.first?.id
            let bar = ProfileBarView(model: model)
            bar.frame = NSRect(x: 0, y: 2, width: 160, height: 28)
            root.addSubview(bar)
            bar.layoutSubtreeIfNeeded()
            bar.refresh()
            guard before else { return }
            // Before: each dot's color with the strip step painted over it, as the bar drew until this change.
            let cover = NSView(frame: bar.frame)
            cover.wantsLayer = true
            root.addSubview(cover)
            let rects = bar.slotRects()
            scope.perform {
                for (index, profile) in model.profiles.enumerated() where rects.indices.contains(index) {
                    let active = index == 0, base = profile.color?.markColor ?? Palette.textPrimary
                    let step = Palette.stripStep.usingColorSpace(.sRGB) ?? .clear, color = base.usingColorSpace(.sRGB) ?? base
                    let k = step.alphaComponent * (active ? 0.25 : 1)
                    let mixed = NSColor(srgbRed: color.redComponent * (1 - k) + step.redComponent * k, green: color.greenComponent * (1 - k) + step.greenComponent * k,
                                        blue: color.blueComponent * (1 - k) + step.blueComponent * k, alpha: ProfileBarView.markAlpha(active: active, hovered: false))
                    let dot = CALayer(), d = Metrics.roomDotDiameter, r = rects[index]
                    dot.frame = CGRect(x: r.midX - d / 2 - 1, y: r.midY - d / 2 - 1, width: d + 2, height: d + 2)
                    dot.cornerRadius = (d + 2) / 2
                    dot.backgroundColor = root.layer?.backgroundColor
                    let inner = CALayer()
                    inner.frame = CGRect(x: 1, y: 1, width: d, height: d)
                    inner.cornerRadius = d / 2
                    inner.backgroundColor = mixed.cgColor
                    dot.addSublayer(inner)
                    cover.layer?.addSublayer(dot)
                }
            }
        }
    }

    static func header(color: GroupColor?, dark: Bool) throws -> CGImage {
        let menu = spaceMenu(color: color)
        let view = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        menu.removeItem(at: 0)
        let width = max(view.frame.width, 300), height = view.frame.height + 16
        return try AAWorkspaceNoColorGalleryTests.draw(width: width, height: height, dark: dark) { root, scope in
            view.adoptMenuScope(scope)
            view.frame = NSRect(x: 0, y: 8, width: width, height: view.frame.height)
            root.addSubview(view)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot, out = root.appending(path: "space-color-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Three header variants: a yellow space dark, a space with no color dark, a green space light.
        let stills: [(String, CGImage)] = [
            ("header-yellow-dark", try Self.header(color: .yellow, dark: true)),
            ("header-no-color-dark", try Self.header(color: nil, dark: true)),
            ("header-green-light", try Self.header(color: .green, dark: false)),
            ("dots-before-dark", try Self.dots(dark: true, before: true)),
            ("dots-after-dark", try Self.dots(dark: true, before: false)),
            ("dots-before-light", try Self.dots(dark: false, before: true)),
            ("dots-after-light", try Self.dots(dark: false, before: false)),
        ]
        for (name, image) in stills { try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png")) }
        // The whole menu as rows, before (the catalog's submenu) and after, as text: what each row is.
        let after = Self.spaceMenu(color: .yellow).items.map { $0.isSeparatorItem ? "---" : $0.view != nil ? "[name field + swatches]" : $0.title + ($0.submenu == nil ? "" : " ›") }
        let before = Self.registry().makeContextMenu(for: .profile, target: Self.target).items.map {
            $0.isSeparatorItem ? "---" : $0.title + ($0.submenu.map { " › [" + $0.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: ", ") + "]" } ?? "")
        }
        try ("before:\n" + before.joined(separator: "\n") + "\n\nafter:\n" + after.joined(separator: "\n") + "\n").write(to: out.appending(path: "menu-rows.txt"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "space-color-gallery.tar", "space-color-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
