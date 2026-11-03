import AppKit
import CmuxNextDesign
import CmuxNextMobile
@testable import CmuxNextMobileHost
import CmuxNextTestSupport
import Testing

/// Fleet capture of the real dialog with synthetic device/account data. Run this test by name;
/// the before images have no prompt, matching the base behavior. No admission is granted.
@MainActor @Suite(.closesItsWindows) struct PhoneAdmissionCaptureTests {
    @Test
    func capturesAllowPrompt() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/phone-access-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Demo iPhone",
                                           identityKey: String(repeating: "b", count: 64), approvalKey: "", transport: .iroh)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // Pin one appearance for the background and the dialog, so a runner in the
            // other system appearance cannot draw dark-mode text on a light backdrop.
            let appearance = try #require(NSAppearance(named: name))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            defer { window.closeAfterTest() }
            let root = try #require(window.contentView)
            root.wantsLayer = true
            appearance.performAsCurrentDrawingAppearance {
                root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            func capture(_ image: String) throws {
                root.layoutSubtreeIfNeeded()
                // 2x pixels regardless of the runner's display scale.
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width) * 2, pixelsHigh: Int(root.bounds.height) * 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = root.bounds.size
                appearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(image)-\(suffix).png"))
            }
            try capture("before-no-prompt")
            let dialog = CmuxDialogView(spec: PhoneAdmission.spec(phone, user: "Demo account"))
            root.addSubview(dialog)
            NSLayoutConstraint.activate([
                dialog.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                dialog.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            #expect(dialog.spec.title.contains("use this Mac"))
            try capture("after-allow-prompt")
        }
    }
}
