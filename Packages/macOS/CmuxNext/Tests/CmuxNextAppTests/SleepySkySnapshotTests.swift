import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// A picture of Sleepy Mode's still scene (Motion off: the sky at time 0), written to
/// `artifacts/sleepy-sky/sky.png` in the checkout, so the canvas sky and the Core Animation sky
/// can be put side by side. Run on a GUI host: split-spring --suite=gui-tests --tests=SleepySkySnapshotTests.
@MainActor @Suite(.serialized, .closesItsWindows) struct SleepySkySnapshotTests {
    @Test(.enabled(if: NSScreen.main != nil, "the scene draws only on a screen: run on a GUI host"))
    func theStillSceneIsWrittenToThePicture() throws {
        _ = NSApplication.shared
        let reduced = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = reduced }
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let host = SleepySceneView.hostView(workingAgents: { 0 }, wake: {}, lockMac: {})
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        let end = Date(timeIntervalSinceNow: 0.5)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../artifacts/sleepy-sky", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("sky.png"))
        print("sleepy sky picture: \(root.appendingPathComponent("sky.png").path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
