import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Native gallery for the first-run Share This Mac guide. Every step uses the real CmuxDialog
/// spec and AppKit card, with both shipped Soft Blue appearances so the permission path is easy to
/// compare before it reaches a person's TCC prompt.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AAMacScreenSetupGalleryTests {
    static let steps = CmuxRemoteSharingSetup.Step.allCases

    static func render(_ step: CmuxRemoteSharingSetup.Step, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 560), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
        let id = center.present(CmuxRemoteSharingSetup.spec(step), in: .window(window)) { _ in }
        defer {
            center.dismiss(id)
            window.close()
        }
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        guard let view = center.dialog(id)?.view else { throw GalleryError.missingDialog }
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(view)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        for child in all(view) {
            child.needsDisplay = true
            child.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-setup-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for step in Self.steps {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                let image = try Self.render(step, theme: theme, dark: dark)
                let url = out.appending(path: "\(step.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-setup-gallery.tar", "mac-screen-setup-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    private enum GalleryError: Error { case missingDialog }
}
