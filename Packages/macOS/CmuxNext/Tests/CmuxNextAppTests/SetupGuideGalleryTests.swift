import AppKit
@testable import CmuxNextApp
import ImageIO
import SwiftUI
import Testing

/// Three quiet reading layouts, using the actual TASKS-derived guide and existing spacing scale.
@MainActor @Suite(.serialized) struct SetupGuideGalleryTests {
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
                let view = NSHostingView(rootView: SetupGuideView(sectionSpacing: spacing, readingWidth: width))
                window.contentView = view
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
