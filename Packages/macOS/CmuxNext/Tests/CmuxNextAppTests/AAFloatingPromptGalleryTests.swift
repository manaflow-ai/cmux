import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
import CmuxNextDevices
@testable import CmuxNextMacScreen
@testable import CmuxNextServer
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The floating prompts as the person meets them: the card at the top right of the screen over another app, in a
/// real floating dialog panel, composited by the window server over a busy backdrop (Leo 2026-11-22: "im
/// not sure what was up with the glass on it, and the lack of theming on it too"). Three prompts (the join consent's
/// control ask, a device asking to control this Mac, Computer use acting as me), each over a wallpaper and over a
/// light page, in Soft Blue Light, Soft Blue and Dracula. Written under `floating-prompt-gallery/` with one sheet per
/// prompt, bundled to `floating-prompt-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAFloatingPromptGalleryTests {
    static let themes: [(name: String, theme: String, dark: Bool)] = [
        ("light", "Soft Blue Light", false), ("dark", "Soft Blue", true), ("dracula", "Dracula", true),
    ]
    static let backdrops = ["wallpaper", "page"]

    /// The prompt's host view, built as the app builds it.
    static func prompt(_ name: String) -> NSView {
        switch name {
        case "join-control":
            let services = JoinConsentServices(status: { nil }, enabled: { true }, askShown: { false }, markAskShown: {})
            let model = JoinConsentModel(services: services)
            model.refused(JoinConsentRefusal(requester: "Desk Mac", surface: .control))
            return JoinConsentAskView(model: model)
        case "screen-control":
            let request = SessionRequest(id: "gallery", viewerId: "v1", viewerName: "Desk Mac",
                                         viewerKeyFingerprint: String(repeating: "3ef8", count: 16), scope: .full)
            let host = CmuxDialogHostView(frame: .zero)
            host.draw(MacScreenApprovalPrompt.spec(request, error: nil)) { _ in }
            return host
        default:
            return AgentPaneActAsMeCardView(grant: AgentPaneActAsMe())
        }
    }

    static let prompts = ["join-control", "screen-control", "act-as-me"]

    /// A busy desktop picture: bright bands and discs, as a wallpaper is.
    final class Wallpaper: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let gradient = NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.2, alpha: 1),
                                               NSColor(srgbRed: 0.85, green: 0.2, blue: 0.55, alpha: 1),
                                               NSColor(srgbRed: 0.2, green: 0.35, blue: 0.9, alpha: 1),
                                               NSColor(srgbRed: 0.1, green: 0.75, blue: 0.7, alpha: 1)])
            gradient?.draw(in: bounds, angle: -35)
            for (index, color) in [NSColor.white.withAlphaComponent(0.55), .black.withAlphaComponent(0.45),
                                   .yellow.withAlphaComponent(0.7), .white.withAlphaComponent(0.8)].enumerated() {
                color.setFill()
                let x = bounds.width * CGFloat(index + 1) / 5, y = bounds.height * (index.isMultiple(of: 2) ? 0.3 : 0.7)
                NSBezierPath(ovalIn: NSRect(x: x - 70, y: y - 70, width: 140, height: 140)).fill()
            }
        }
    }

    /// Another app's light window: a toolbar, a headline, paragraphs and a picture.
    final class Page: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: bounds.height - 36, width: bounds.width, height: 36).fill()
            NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1).setFill()
            NSRect(x: bounds.width - 220, y: 30, width: 180, height: 120).fill()
            let words = "Quarterly planning notes: the release ships Tuesday, then the team reviews the metrics and the open "
                + "issues. Design wants one more pass on the onboarding flow before it goes out to everyone. "
            let text = String(repeating: words, count: 6) as NSString
            text.draw(in: bounds.insetBy(dx: 24, dy: 48).offsetBy(dx: 0, dy: -12),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            ("Team sync" as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 70),
                                           withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
        }
    }

    static func capture(_ prompt: String, theme: String, dark: Bool, backdrop: String) throws -> CGImage {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input(theme))
        let panel = CmuxFloatingDialogPanel(identifier: "gallery.floatingPrompt")
        panel.appearance = NSApp.appearance
        let content = Self.prompt(prompt)
        panel.present(content)
        let card = try #require(panel.cardFrame)
        let frame = card.insetBy(dx: -48, dy: -40)
        let back = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .normal
        let view: NSView = backdrop == "page" ? Page(frame: NSRect(origin: .zero, size: frame.size))
                                              : Wallpaper(frame: NSRect(origin: .zero, size: frame.size))
        back.contentView = view
        back.setFrame(frame, display: true)
        back.orderFrontRegardless()
        panel.orderFrontRegardless()
        defer {
            panel.hide()
            panel.close()
            back.close()
        }
        for _ in 0..<12 {
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try #require(back.compositedSnapshot(adding: [panel]))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        // The look Settings > Experiments > Themed Floating Prompts turns on (off by default).
        try DesignSettings.$themedPromptsOverride.withValue(true) { try renderGalleryOn() }
    }

    private func renderGalleryOn() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        _ = NSApplication.shared
        // The app's own window, as the app has one: the floating card keeps its glass's key look from its
        // ``ActiveLookScope`` while cmux is not active (``CmuxFloatingDialogPanel/appActiveLook``).
        let appWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        appWindow.isReleasedWhenClosed = false
        appWindow.contentView = WindowSurfaceView(content: NSView(), activeLook: ActiveLookScope())
        defer { appWindow.close() }
        let icon = AANestedGroupsGalleryTests.repoRoot.appending(path: "design/cmux-icon-chevron.png")
        let savedIcon = NSApp.applicationIconImage
        NSApp.applicationIconImage = NSImage(contentsOf: icon) ?? savedIcon
        defer { NSApp.applicationIconImage = savedIcon }
        #expect(CmuxFloatingDialogPanel.appActiveLook != nil)
        let out = root.appending(path: "floating-prompt-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for prompt in Self.prompts {
            // One row per backdrop; columns: the themes.
            var rows: [[CGImage]] = []
            for backdrop in Self.backdrops {
                var row: [CGImage] = []
                for (name, theme, dark) in Self.themes {
                    let image = try Self.capture(prompt, theme: theme, dark: dark, backdrop: backdrop)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(prompt)-\(name)-\(backdrop).png"))
                    row.append(image)
                }
                rows.append(row)
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(rows), to: out.appending(path: "\(prompt)-all.png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "floating-prompt-gallery.tar", "floating-prompt-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    /// The images in a grid on a mid gray, one row each.
    static func sheet(_ rows: [[CGImage]]) throws -> CGImage {
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1
        let cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let columns = rows.map(\.count).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: columns * (cellW + gap) + gap, height: rows.count * (cellH + gap) + gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                let top = ctx.height - gap - r * (cellH + gap)
                ctx.draw(image, in: CGRect(x: gap + c * (cellW + gap), y: top - image.height, width: image.width, height: image.height))
            }
        }
        return try #require(ctx.makeImage())
    }
}
