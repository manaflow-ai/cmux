import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The Tab Bar Playground's Corner Radius page (Debug menu, DEV and NIGHTLY), drawn from its real
/// rows (real tab strips in pane cards at each radius/padding pair), light and dark: the sheet a
/// fleet run returns (`--artifact Packages/macOS/CmuxNext/.build/concentric-corner-playground.png`).
/// Each row's pills must be the pair's inner radius, so the sheet shows what the rule draws.
@MainActor @Suite(.serialized, .closesItsWindows) struct ConcentricCornerPlaygroundShotTests {
    @Test func theCornerRadiusPageRendersToASheet() throws {
        _ = NSApplication.shared
        var shots: [(String, CGImage)] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let variants = ConcentricCornerPlaygroundVariants().all
            let width: CGFloat = 720, rowHeight = ConcentricCornerPlaygroundRow.preferredHeight
            let host = PlaygroundSheetHost(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(variants.count)))
            host.wantsLayer = true
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            for (index, variant) in variants.enumerated() {
                let row = try #require(variant.make(4) as? ConcentricCornerPlaygroundRow)
                row.frame = NSRect(x: 0, y: rowHeight * CGFloat(index), width: width, height: rowHeight)
                host.addSubview(row)
                row.layoutSubtreeIfNeeded()
                let pair = ConcentricCornerPlaygroundVariants.pairs[index]
                let inner = ConcentricCorners(outer: pair.outer, padding: pair.padding).inner
                let strip = try #require(row.subviews.compactMap { $0 as? TabStripView }.first)
                strip.layoutSubtreeIfNeeded()
                for cell in strip.cells.values {
                    #expect(abs(cell.backgroundLayer.cornerRadius - min(inner, strip.metrics.tabHeight / 2)) <= 0.01,
                            "\(variant.name): a tab is \(cell.backgroundLayer.cornerRadius) pt")
                }
            }
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            shots.append((appearance == .aqua ? "Light" : "Dark", try TabConcentricCornerTests.upright(host)))
        }
        let sheet = PaneMoreShotsTests.contactSheet(shots)
        let out = PaneMoreShotsTests.packageRoot.appending(path: ".build/concentric-corner-playground.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])).write(to: out)
        print("concentric-corner-playground: wrote \(out.path)")
    }
}

/// A top-down host, as the playground's document view is.
private final class PlaygroundSheetHost: NSView {
    override var isFlipped: Bool { true }
}
