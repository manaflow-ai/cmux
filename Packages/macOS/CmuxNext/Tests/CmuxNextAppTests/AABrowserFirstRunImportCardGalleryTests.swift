import AppKit
import CmuxNextBrowserImport
@testable import CmuxNextDesign
@testable import CmuxNextOnboarding
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The first-run import card's stills (RFD 0125 D4), light and dark: Chrome into a new profile,
/// Arc into an existing one (the cookie replacement stated), Safari (no mirror line) and Chrome
/// with the mirror off and Extensions checked. Written as PNGs under
/// `browser-first-run-import-gallery/` in the package and bundled to
/// `browser-first-run-import-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AABrowserFirstRunImportCardGalleryTests {
    static let packageRoot = AANestedGroupsGalleryTests.packageRoot
    static let profiles = [FirstRunImportPlan.Profile(id: "default", name: "Default"), FirstRunImportPlan.Profile(id: "p2", name: "Personal")]

    struct Variant {
        var name: String
        var app: String
        var plan: FirstRunImportPlan
    }

    static var variants: [Variant] {
        let chromeNew = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome · Work", profiles: [], mirrorOn: true)
        var arcExisting = FirstRunImportPlan(browser: .arc, sourceProfile: "Arc", profiles: profiles, mirrorOn: true)
        arcExisting.selectDestination(at: 2)
        let safari = FirstRunImportPlan(browser: .safari, sourceProfile: "Safari", profiles: profiles, mirrorOn: true)
        var chromeOff = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome · Personal", profiles: profiles, mirrorOn: false)
        chromeOff.toggle(.extensions)
        return [
            Variant(name: "chrome-new-profile", app: "/Applications/Google Chrome.app", plan: chromeNew),
            Variant(name: "arc-existing-profile", app: "/Applications/Arc.app", plan: arcExisting),
            Variant(name: "safari-no-mirror", app: "/Applications/Safari.app", plan: safari),
            Variant(name: "chrome-mirror-off", app: "/Applications/Google Chrome.app", plan: chromeOff),
        ]
    }

    static func icon(_ app: String) -> NSImage? {
        let image = FileManager.default.fileExists(atPath: app) ? NSWorkspace.shared.icon(forFile: app)
            : NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    static func render(_ variant: Variant, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let card = FirstRunImportCardView(plan: variant.plan, icon: icon(variant.app))
        card.translatesAutoresizingMaskIntoConstraints = false
        let fitting = card.fittingSize
        let margin: CGFloat = 24
        let size = NSSize(width: fitting.width + margin * 2, height: fitting.height + margin * 2)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
        ])
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.needsLayout = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: "browser-first-run-import-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for variant in Self.variants {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                let image = try Self.render(variant, theme: theme, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.name)-\(mode).png"))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "browser-first-run-import-gallery.tar", "browser-first-run-import-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
