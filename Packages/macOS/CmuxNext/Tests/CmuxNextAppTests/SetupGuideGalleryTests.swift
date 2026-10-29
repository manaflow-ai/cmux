import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxTheme
import ImageIO
import Testing

/// Three quiet reading layouts, using the actual TASKS-derived guide and existing spacing scale.
@MainActor @Suite(.serialized) struct SetupGuideGalleryTests {
    @Test func instructionsWrapWhenPaneNarrows() throws {
        let view = SetupGuideView()
        var wideHeight: CGFloat = 0
        for width in [680.0, 280.0] {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let scroll = try #require(view.subviews.first as? NSScrollView)
            let document = try #require(scroll.documentView)
            let labels = document.subviews.compactMap { $0 as? NSTextField }
            #expect(labels.count == 13)
            let rows = document.subviews
            for (first, second) in zip(rows, rows.dropFirst()) {
                #expect(first.frame.maxY <= second.frame.minY)
            }
            #expect(rows.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= document.bounds.width })
            #expect(try #require(rows.last).frame.maxY <= document.bounds.height)
            if width == 680 { wideHeight = document.bounds.height }
            else { #expect(document.bounds.height > wideHeight) }
        }
    }

    @Test func githubActionRequiresThePersonClick() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "accounts.githubConnect" })
        let registry = ActionRegistry(catalog: [descriptor])
        var origins: [ActionOrigin] = []
        registry.bindEffect("accounts.githubConnect", effect: { invocation in
            origins.append(invocation.origin)
            return .done
        })
        let page = SetupGuidePage(registry: registry)
        let view = page.makeView(for: "", in: nil)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.subviews.first as? NSScrollView)
        let document = try #require(scroll.documentView)
        let button = try #require(document.subviews.compactMap { $0 as? NSButton }.first)
        #expect(origins.isEmpty)
        #expect(button.accessibilityIdentifier() == "setup-guide-accounts-action")
        button.performClick(nil)
        #expect(origins == [.user])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.appending(path: "setup-guide-gallery")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, spacing, width) in [("compact", 16.0, 600.0), ("balanced", 24.0, 680.0), ("roomy", 32.0, 760.0)] {
            for (mode, dark) in [("light", false), ("dark", true)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.close() }
                let view = SetupGuideView(sectionSpacing: spacing, readingWidth: width)
                window.contentView = view
                let theme = dark ? "Soft Blue" : "Soft Blue Light"
                let scope = ThemeScope(level: .room)
                scope.setOverride(ThemeSpec(theme), input: try AANestedGroupsGalleryTests.input(theme), animated: false)
                scope.root(view)
                view.wantsLayer = true
                view.layer?.backgroundColor = scope.perform { Palette.windowBackground }.cgColor
                window.orderFrontRegardless()
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = try #require(rep.cgImage)
                let destination = try #require(CGImageDestinationCreateWithURL(
                    output.appending(path: "\(name)-\(mode).png") as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = package
        tar.arguments = ["cf", "setup-guide-gallery.tar", "setup-guide-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
