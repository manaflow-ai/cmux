import AppKit
import CmuxNextDesign
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Testing

/// Fleet capture of the real dialog with synthetic device/account data. Run this test by name;
/// the before image has no prompt, matching the base behavior. No admission is granted.
@MainActor struct PhoneAdmissionCaptureTests {
    @Test
    func capturesAllowPrompt() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/phone-access-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let caption = NSTextField(labelWithString: "Phone Access")
        caption.frame = NSRect(x: 24, y: 430, width: 200, height: 24)
        root.addSubview(caption)
        func capture(_ name: String) throws {
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try capture("before-no-prompt")
        let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Demo iPhone",
                                           identityKey: String(repeating: "b", count: 64), approvalKey: "", transport: .iroh)
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
