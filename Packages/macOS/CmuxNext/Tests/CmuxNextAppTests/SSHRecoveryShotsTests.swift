import AppKit
import CmuxNextDesign
import CmuxNextServer
import Foundation
import QuartzCore
import Vision
import CmuxNextTestSupport
import Testing

/// Three recovery layouts, using the shipped dialog and a public example destination.
/// The balanced layout keeps the cause and all actions in one persistent sheet.
@MainActor @Suite(.serialized, .closesItsWindows) struct SSHRecoveryShotsTests {
    @Test func recoveryVariantsRenderInLightAndDark() throws {
        _ = NSApplication.shared
        let detail = "Could not resolve hostname nohost.invalid: nodename nor servname provided, or not known"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var shots: [(String, NSImage)] = []
            for variant in ["compact", "balanced", "details"] {
                var spec = SSHConnectRecovery.spec(title: "Cannot Connect to nohost.invalid", detail: detail, cancel: "Cancel", copy: "Copy Error", check: "Check Machine", retry: "Retry")
                if variant == "compact" { spec.lines = ["Could not resolve hostname nohost.invalid."] }
                if variant == "details" { spec.lines = ["nohost.invalid", detail] }
                let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
                let id = center.present(spec, in: .app) { _ in }
                let view = try #require(center.view(id))
                view.appearance = NSAppearance(named: appearance)
                let image = try Self.render(view, appearance: appearance)
                #expect(image.size.width >= 300)
                shots.append(("\(appearance.rawValue) \(variant)", image))
                center.dismiss(id)
            }
            let mode = appearance == .aqua ? "light" : "dark"
            let out = AddServerShotsTests.packageRoot.appending(path: ".build/ssh-recovery-shots-\(mode).png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AddServerShotsTests.png(AddServerShotsTests.contactSheet(shots)).write(to: out)
            print("ssh-recovery-shots: wrote \(out.path)")
        }
    }

    private static func render(_ view: NSView, appearance: NSAppearance.Name) throws -> NSImage {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = root
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        func display(_ node: NSView) {
            node.needsDisplay = true
            node.displayIfNeeded()
            node.subviews.forEach(display)
        }
        display(root)
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let cg = try #require(rep.cgImage)
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cg).perform([text])
        let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(words.contains("Cannot Connect"), "Gallery must draw the title: \\(words)")
        #expect(words.contains("Retry"), "Gallery must draw recovery actions: \\(words)")
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
