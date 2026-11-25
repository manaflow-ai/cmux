import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import CmuxTheme
import ImageIO
import Testing

/// Own fixture windows only: before and three chip layouts, in both appearance modes.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAHomeStarterGalleryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let width = 460, height = 760
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let sheet = try #require(CGContext(data: nil, width: width * 4, height: height * 2, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (row, appearance) in [("Soft Blue Light", false), ("Soft Blue", true)].enumerated() {
            for (column, look) in ([nil] + HomeStarterChips.Look.allCases.map(Optional.some)).enumerated() {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance.1 ? .darkAqua : .aqua)
                defer { window.close() }
                let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                window.contentView = panel
                let input = try AANestedGroupsGalleryTests.input(appearance.0)
                let scope = ThemeScope(level: .room)
                scope.setOverride(ThemeSpec(appearance.0), input: input, animated: false)
                scope.root(panel)
                panel.wantsLayer = true
                scope.perform {
                    panel.layer?.backgroundColor = Palette.windowBackground.cgColor
                    panel.applyColors(primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary,
                                      fill: Palette.elevatedBackground, hover: Palette.hoverFill, border: Palette.separator,
                                      attention: Palette.attention, danger: Palette.danger, done: Palette.highlight)
                }
                panel.hero.setAvatar(picture: nil, text: nil, name: "Chief")
                panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: nil)
                if let look {
                    panel.starters.look = look
                    panel.starters.setPrompts(HomeStarterContext(workspaces: ["todo-app"], working: ["Add search"],
                                                                failures: ["Test search"], pullRequests: ["sample/todo#42"]).prompts)
                }
                window.orderFrontRegardless()
                panel.layoutSubtreeIfNeeded()
                for view in AANestedGroupsGalleryTests.all(panel) { view.needsDisplay = true; view.displayIfNeeded() }
                CATransaction.flush()
                let rep = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
                panel.cacheDisplay(in: panel.bounds, to: rep)
                sheet.draw(try #require(rep.cgImage), in: CGRect(x: column * width, y: (1 - row) * height, width: width, height: height))
            }
        }
        let output = AANestedGroupsGalleryTests.packageRoot.appending(path: "chief-starters-gallery.png")
        let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(sheet.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
