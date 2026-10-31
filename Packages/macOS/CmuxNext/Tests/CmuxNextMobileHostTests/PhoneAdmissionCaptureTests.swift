import AppKit
import CmuxNextDesign
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Testing

/// Fleet capture of the real dialog with synthetic device/account data. Run this test by name;
/// the before image has no prompt, matching the base behavior. No admission is granted.
@MainActor @Suite(.serialized) struct PhoneAdmissionCaptureTests {
    /// Whether AppKit can put a window on screen here (a worker at the login window cannot).
    static func hostShowsWindows() -> Bool {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { return false }
        let probe = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.close() }
        probe.orderFrontRegardless()
        return probe.isVisible && probe.windowNumber > 0
    }

    /// Writes before/after stills, 2x, in light and dark, to `artifacts/phone-access-capture/` at the
    /// repository root (found from this file), so a fleet step can return them by path. The window is on
    /// screen and the image comes from the window server, since the dialog's glass draws only there.
    @Test(.enabled("this host puts windows on screen") { PhoneAdmissionCaptureTests.hostShowsWindows() },
          arguments: ["light", "dark"])
    func capturesAllowPrompt(appearance: String) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/phone-access-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        content.wantsLayer = true
        window.contentView = content
        let caption = NSTextField(labelWithString: "Phone Access")
        caption.frame = NSRect(x: 24, y: 320, width: 200, height: 24)
        content.addSubview(caption)
        window.orderFrontRegardless()
        func capture(_ name: String) async throws {
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            CATransaction.flush()
            // The window server composites an ordered-in window, and the dialog's appear fade, over a
            // few frames; wait past them.
            try await Task.sleep(for: .milliseconds(800))
            let image = try #require(window.compositedSnapshotWithOverlays()?.image)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(appearance)@2x.png"))
        }
        try await capture("before-no-prompt")
        let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Demo iPhone",
                                           identityKey: String(repeating: "b", count: 64), approvalKey: "", transport: .iroh)
        let dialog = CmuxDialogView(spec: PhoneAdmission.spec(phone, user: "Demo account"))
        content.addSubview(dialog)
        NSLayoutConstraint.activate([
            dialog.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dialog.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        #expect(dialog.spec.title.contains("use this Mac"))
        try await capture("after-allow-prompt")
    }
}
