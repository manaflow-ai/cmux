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
        // Each pass draws in a theme of its own brightness, as the app does: a window's light or dark look comes
        // from its theme scope (`ThemeScope.adopt`), and the dialog's ink is that theme's. Forcing only the look
        // left the test's app scope on Ghostty's default dark theme, so the "light" pass drew the dark theme's
        // near-white title and Cancel/Copy/Check labels over a light card and OCR read only the gray detail and
        // the filled Retry button (job a821ec925b5cb01e0d3dd11f, 5 of 5).
        for (appearance, input) in [(NSAppearance.Name.aqua, Self.lightTheme), (.darkAqua, ThemeInput.ghosttyDefault)] {
            let scope = ThemeScope(level: .room)
            scope.setOverride(try #require(ThemeSpec("SSH Recovery \(appearance.rawValue)")), input: input, animated: false)
            #expect(scope.appearance.name == appearance)
            var shots: [(String, NSImage)] = []
            for variant in ["compact", "balanced", "details"] {
                var spec = SSHConnectRecovery.spec(title: "Cannot Connect to nohost.invalid", detail: detail, cancel: "Cancel", copy: "Copy Error", check: "Check Machine", retry: "Retry")
                if variant == "compact" { spec.lines = ["Could not resolve hostname nohost.invalid."] }
                if variant == "details" { spec.lines = ["nohost.invalid", detail] }
                let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
                let id = center.present(spec, in: .app) { _ in }
                let view = try #require(center.view(id))
                let image = try Self.render(view, in: scope)
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

    /// A light terminal theme (white background, near-black text), as `CmuxDialogLightContrastTests` uses.
    private static let lightTheme = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))

    /// Captures `view` in a window that adopted `scope`, over the scope's window background: what a person sees
    /// behind a dialog in that theme.
    private static func render(_ view: NSView, in scope: ThemeScope) throws -> NSImage {
        // At least the dialog's own fitting size plus a margin: the stacked actions and a wrapped detail make the
        // card taller on some Macs (fonts, scale) than a fixed 420x280 root, which clipped the title off the top.
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        let root = NSView(frame: NSRect(x: 0, y: 0, width: max(420, ceil(fit.width) + 40), height: max(280, ceil(fit.height) + 40)))
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        scope.adopt(window)
        root.wantsLayer = true
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground }.cgColor
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
        func find(_ node: NSView) -> ChromeLabel? {
            if let label = node as? ChromeLabel, label.stringValue.hasPrefix("Cannot Connect") { return label }
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
