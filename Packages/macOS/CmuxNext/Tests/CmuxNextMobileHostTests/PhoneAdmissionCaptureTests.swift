import AppKit
import CmuxNextDesign
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Testing

/// Fleet capture of the real dialog with synthetic device/account data. Run this test by name;
/// the before image has no prompt, matching the base behavior. No admission is granted.
@MainActor struct PhoneAdmissionCaptureTests {
    /// The window backdrop, drawn in `draw(_:)` so `cacheDisplay` paints it in the window's appearance.
    final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    /// Writes before/after stills, 2x, in light and dark, to `artifacts/phone-access-capture/` at the
    /// repository root (found from this file), so a fleet step can return them by path.
    @Test(arguments: ["light", "dark"])
    func capturesAllowPrompt(appearance: String) throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/phone-access-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        defer { window.close() }
        let content = Backdrop(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        window.contentView = content
        let caption = NSTextField(labelWithString: "Phone Access")
        caption.frame = NSRect(x: 24, y: 320, width: 200, height: 24)
        content.addSubview(caption)
        func capture(_ name: String) throws {
            content.layoutSubtreeIfNeeded()
            var png: Data?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                let size = content.bounds.size
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                    pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                bitmap.size = size
                content.cacheDisplay(in: content.bounds, to: bitmap)
                png = bitmap.representation(using: .png, properties: [:])
            }
            try #require(png).write(to: directory.appendingPathComponent("\(name)-\(appearance)@2x.png"))
        }
        try capture("before-no-prompt")
        let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Demo iPhone",
                                           identityKey: String(repeating: "b", count: 64), approvalKey: "", transport: .iroh)
        let dialog = CmuxDialogView(spec: PhoneAdmission.spec(phone, user: "Demo account"))
        content.addSubview(dialog)
        NSLayoutConstraint.activate([
            dialog.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dialog.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        #expect(dialog.spec.title.contains("use this Mac"))
        try capture("after-allow-prompt")
    }
}
