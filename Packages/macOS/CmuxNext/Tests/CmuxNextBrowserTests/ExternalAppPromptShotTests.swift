import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// Renders the open-another-app prompt bar (with and without "Always allow")
/// over a light and a dark page into artifacts/external-app-prompt.png at the
/// checkout's top, for before/after pictures of its design.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct ExternalAppPromptShotTests {
    @Test func rendersTheOpenAppPrompt() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 1040, height: 400)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        window.contentView = root
        for (column, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let page = NSView(frame: CGRect(x: CGFloat(column) * size.width / 2, y: 0, width: size.width / 2, height: size.height))
            page.wantsLayer = true
            page.appearance = NSAppearance(named: name)
            page.layer?.backgroundColor = (name == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)).cgColor
            root.addSubview(page)
            for (row, origin) in ["https://app.slack.com", ""].enumerated() {
                let bar = PromptBarView()
                page.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.centerXAnchor.constraint(equalTo: page.centerXAnchor),
                    bar.topAnchor.constraint(equalTo: page.topAnchor, constant: 24 + CGFloat(row) * 190),
                    bar.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -40),
                ])
                bar.show(BrowserPrompt(kind: .openExternalApp(app: "Slack", scheme: "slack"), origin: origin) { _ in })
            }
        }
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(400))
        let image: CGImage
        if let shot = try? await window.screenshotImage() {
            image = shot
        } else {
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            image = try #require(bitmap.cgImage)
        }
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardized
        let out = top.appendingPathComponent("artifacts/external-app-prompt.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out)
        #expect(png.count > 1000)
    }
}
