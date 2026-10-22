import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Scratch only (never landed): renders the sidebar footer to PNGs for the home-footer-sizes gallery.
@MainActor @Suite(.serialized) struct FooterShotCaptureTests {
    @Test func renderFooterShots() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("footer-shots")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["Default", "Side", "Studio", "Sketch", "Scratch"]
        for (look, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            for width in [CGFloat(240), 180] {
                for hover in [false, true] {
                    let model = SidebarModel()
                    model.profileAvatar = .account(name: "lawrence@manaflow.ai")
                    model.profiles = names.enumerated().map { SidebarProfile(id: ProfileKey("s\($0.offset)"), name: $0.element) }
                    model.activeProfileID = model.profiles.first?.id
                    let sidebar = SidebarView(model: model, design: DesignSettings())
                    let height: CGFloat = 400
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearanceName)
                    window.contentView = sidebar
                    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    for _ in 0..<30 {
                        sidebar.renderNow()
                        sidebar.needsLayout = true
                        sidebar.layoutSubtreeIfNeeded()
                        if sidebar.footerBand.profileControl != nil { break }
                        await Task.yield()
                    }
                    if hover { sidebar.profileBar.setPointerInside(true); sidebar.profileBar.setHovered(ProfileBarView.plusIndex) }
                    sidebar.layoutSubtreeIfNeeded()
                    sidebar.displayIfNeeded()
                    let band: CGFloat = 52
                    let crop = NSRect(x: 0, y: sidebar.isFlipped ? height - band : 0, width: width, height: band)
                    let scale: CGFloat = 2
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(band * scale),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = NSSize(width: width, height: band)
                    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    (look == "dark" ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                    NSRect(x: 0, y: 0, width: width, height: band).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    let layered = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    layered.size = NSSize(width: width, height: height)
                    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
                        sidebar.cacheDisplay(in: sidebar.bounds, to: layered)
                    }
                    let full = NSImage(size: NSSize(width: width, height: height)); full.addRepresentation(layered)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    full.draw(in: NSRect(x: 0, y: 0, width: width, height: band),
                              from: NSRect(x: 0, y: 0, width: width, height: band), operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                    let name = "\(look)-\(Int(width))\(hover ? "-hover" : "").png"
                    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
                    let control = sidebar.footerBand.profileControl.map { sidebar.convert($0.view.avatarView.circleFrame, from: $0.view.avatarView) }
                    let rects = sidebar.profileBar.slotRects().map { sidebar.convert($0, from: sidebar.profileBar) }
                    let line = "\(name) avatar=\(control.map { "\($0)" } ?? "nil") slots=\(rects)\n"
                    let metrics = dir.appendingPathComponent("metrics.txt")
                    if let handle = try? FileHandle(forWritingTo: metrics) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
                    else { try Data(line.utf8).write(to: metrics) }
                    window.close()
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", root.appendingPathComponent("footer-shots.tgz").path, "-C", root.path, "footer-shots"]
        try tar.run(); tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
