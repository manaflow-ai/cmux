import AppKit
@testable import CmuxNextApps
import Foundation
import SwiftUI
import Testing

/// The custom sidebar examples (examples/custom-sidebars) drawn by the native scene renderer from
/// the scene ops their scripts send (examples/custom-sidebars/scenes, written by
/// cmux-tui/crates/cmux-app-host/js/test/custom-sidebar-fixtures.ts). Each must lay out every
/// workspace row; the test also writes a side-by-side PNG for the gallery to
/// `.build/artifacts/custom-sidebar-gallery.png` at the repo root.
@MainActor
@Suite(.serialized) struct CustomSidebarGalleryTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../..").standardizedFileURL
    nonisolated static let names = ["dots", "board", "cards"]
    static let size = NSSize(width: 260, height: 620)

    static func model(_ name: String) throws -> AppSceneModel {
        let url = repo.appendingPathComponent("examples/custom-sidebars/scenes/\(name).json")
        let model = AppSceneModel()
        model.apply(AppSceneOp.batch(try AppJSON.parse(Data(contentsOf: url))))
        return model
    }

    static func render(_ model: AppSceneModel, dark: Bool) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        let host = AppCustomSidebarHostingView(model: model, bundleDirectory: nil)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    @Test(arguments: names) func anExampleRendersEveryWorkspace(_ name: String) throws {
        let model = try Self.model(name)
        #expect(model.status == .ready)
        let titles = model.scene.nodes.values.compactMap { $0.type == .text ? $0.string("text") : nil }
        for title in ["api-gateway", "web-dashboard", "ios-release", "scratch"] {
            #expect(titles.contains(title), "\(name) shows \(title)")
        }
        #expect(Self.render(model, dark: true) != nil)
    }

    @Test func writesTheGallerySheet() throws {
        let gap: CGFloat = 16
        let width = (Self.size.width + gap) * CGFloat(Self.names.count) + gap
        let height = (Self.size.height + gap) * 2 + gap
        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (row, dark) in [true, false].enumerated() {
            let back = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
            for (column, name) in Self.names.enumerated() {
                let frame = NSRect(x: gap + CGFloat(column) * (Self.size.width + gap),
                                   y: height - CGFloat(row + 1) * (Self.size.height + gap), width: Self.size.width, height: Self.size.height)
                back.setFill()
                frame.fill()
                let rep = try #require(Self.render(try Self.model(name), dark: dark))
                rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let out = Self.repo.appendingPathComponent(".build/artifacts/custom-sidebar-gallery.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out)
        // The fleet returns artifacts of green runs only; the log carries the sheet either way.
        print("CUSTOM_SIDEBAR_GALLERY_PNG_BASE64 " + png.base64EncodedString())
        #expect(png.count > 10_000)
    }
}
