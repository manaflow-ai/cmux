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
        // The theme's ink follows the app's look, not only the view's: on a Mac whose system look is the other one,
        // the primary-ink title and buttons drew in the wrong appearance's text color on the card and OCR lost them.
        let appLook = NSApp.appearance
        defer { NSApp.appearance = appLook }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
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
        // At least the dialog's own fitting size plus a margin: the stacked actions and a wrapped detail make the
        // card taller on some Macs (fonts, scale) than a fixed 420x280 root, which clipped the title off the top.
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        let root = NSView(frame: NSRect(x: 0, y: 0, width: max(420, ceil(fit.width) + 40), height: max(280, ceil(fit.height) + 40)))
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
        #expect(words.contains("Cannot Connect"), "Gallery must draw the title: \(words); \(Self.titleInk(in: root, rep: rep))")
        #expect(words.contains("Retry"), "Gallery must draw recovery actions: \(words)")
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// What the capture holds under the title: its label's ink, the theme's light or dark, and the
    /// darkest and lightest captured pixels in its frame (white text on a white card reads as one value).
    private static func titleInk(in root: NSView, rep: NSBitmapImageRep) -> String {
        func find(_ node: NSView) -> NSTextField? {
            if let field = node as? NSTextField, field.stringValue.hasPrefix("Cannot Connect") { return field }
            return node.subviews.lazy.compactMap(find).first
        }
        guard let title = find(root) else { return "no title label" }
        let frame = title.convert(title.bounds, to: root)
        let scale = CGFloat(rep.pixelsWide) / max(root.bounds.width, 1)
        var low = 1.0, high = 0.0, alpha = 1.0
        for y in stride(from: Int(frame.minY * scale), to: Int(frame.maxY * scale), by: 1) {
            for x in stride(from: Int(frame.minX * scale), to: Int(frame.maxX * scale), by: 2) {
                guard let color = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                let luma = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                low = min(low, luma)
                high = max(high, luma)
                alpha = min(alpha, color.alphaComponent)
            }
        }
        let ink = title.textColor?.usingColorSpace(.sRGB).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "nil"
        return "title ink \(ink), theme dark \(title.themeTokens.isDark), look \(title.effectiveAppearance.name.rawValue), "
            + "captured luma \(low)...\(high), min alpha \(alpha), frame \(frame)"
    }
}
