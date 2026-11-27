import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// The contact sheet a fleet run returns for the one corner rule on every surface: at the default
/// corners, a large radius with a wide padding and a small radius, it draws a popover card with two
/// rows and a button in it, a toast, a terminal banner, a sidebar row and the omnibar, each shape
/// rounded with the radius its real surface reports (`PopupStyle`, `FloatingGlassStyle.toast`, a
/// live `TerminalStatusBanner`, `SidebarDensityTokens`, `OmnibarStyle`). A surface that keeps a
/// fixed radius draws the same corner in every row.
@MainActor @Suite(.serialized, .closesItsWindows) struct ConcentricSurfaceShotTests {
    private func load(radius: Double?, padding: Double?) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        if let padding { layout["cornerPadding"] = .number(padding) }
        let snapshot = CmuxConfigSnapshot.parse(.object(["layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = .compact
    }

    @Test func theSurfacesRenderToTheContactSheet() throws {
        defer { load(radius: nil, padding: nil) }
        var shots: [(String, CGImage)] = []
        for (radius, padding) in [(Double?.none, Double?.none), (16, 4), (6, 1)] {
            load(radius: radius, padding: padding)
            let title = radius.map { "radius \(Int($0)), padding \(Int(padding ?? 0))" } ?? "unset (defaults)"
            shots.append((title, try Self.render()))
        }
        let sheet = PaneMoreShotsTests.contactSheet(shots)
        let out = PaneMoreShotsTests.packageRoot.appending(path: ".build/concentric-surfaces.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])).write(to: out)
        print("concentric-surfaces: wrote \(out.path)")
    }

    /// One row of the sheet at the corners loaded now.
    static func render() throws -> CGImage {
        let size = CGSize(width: 760, height: 150)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let base = try #require(root.layer)
        base.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        func shape(_ frame: CGRect, _ radius: CGFloat, white: CGFloat, in parent: CALayer, rim: Bool = false) -> CALayer {
            let layer = CALayer()
            layer.frame = frame
            layer.cornerRadius = radius
            layer.cornerCurve = .circular
            layer.backgroundColor = NSColor(white: white, alpha: 1).cgColor
            if rim { (layer.borderColor, layer.borderWidth) = (NSColor(white: 1, alpha: 0.25).cgColor, 1) }
            parent.addSublayer(layer)
            return layer
        }
        // A popover card: two rows `padding` inside it (the second highlighted) and a button in the first.
        let popup = PopupStyle.standard
        let card = shape(CGRect(x: 16, y: 16, width: 220, height: 118), popup.cornerRadius, white: 0.2, in: base, rim: true)
        let rowWidth = card.bounds.width - 2 * popup.padding
        _ = shape(CGRect(x: popup.padding, y: popup.padding, width: rowWidth, height: popup.rowHeight), popup.rowCornerRadius,
                  white: 0.28, in: card)
        _ = shape(CGRect(x: popup.padding, y: popup.padding + popup.rowHeight + 2, width: rowWidth, height: popup.rowHeight),
                  popup.rowCornerRadius, white: 0.42, in: card)
        _ = shape(CGRect(x: card.bounds.width - popup.padding - 70, y: card.bounds.height - popup.padding - 30, width: 62, height: 22),
                  Metrics.itemCornerRadius, white: 0.5, in: card)
        // A toast, a terminal banner (its live layer's radius), a sidebar row and the omnibar.
        _ = shape(CGRect(x: 256, y: 16, width: 220, height: 44), FloatingGlassStyle.toast.cornerRadius, white: 0.3, in: base, rim: true)
        _ = shape(CGRect(x: 256, y: 76, width: 220, height: 58), TerminalStatusBanner().layer?.cornerRadius ?? 0, white: 0.24, in: base, rim: true)
        _ = shape(CGRect(x: 496, y: 16, width: 248, height: 28), SidebarDensityTokens.rowCornerRadius, white: 0.32, in: base)
        _ = shape(CGRect(x: 496, y: 64, width: 248, height: 30), OmnibarStyle.barCornerRadius, white: 0.36, in: base, rim: true)
        let scale: CGFloat = 2
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        base.render(in: context)
        return try #require(context.makeImage())
    }
}
