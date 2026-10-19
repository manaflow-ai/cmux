import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// With CMUX_GLASS_LEGIBILITY_GALLERY (a folder), renders the window's backdrop (the bundled art,
/// the glass tint at the legibility floor) with primary, secondary and tertiary text over it, once
/// per Glass Over Art choice, to glass-legibility-<choice>.png there. "all" is the floor cmux
/// had before; "primary" is the iOS-style default.
@MainActor @Suite(.serialized) struct GlassLegibilityGalleryTests {
    @Test func galleryOfEachChoice() async throws {
        guard let out = ProcessInfo.processInfo.environment["CMUX_GLASS_LEGIBILITY_GALLERY"] else { return }
        _ = NSApplication.shared
        let images = BackdropImageStore(maxPixelSize: 1600)
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        var notes: [String] = []
        for art in [BackdropArt.friedrichWanderer, .vermeerPearlEarring] {
        _ = try #require(await images.image(.art(art)), "the bundled art does not decode")
        for legibility in ArtLegibility.allCases {
            let frame = NSRect(x: 0, y: 0, width: 1200, height: 750)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: frame)
            root.wantsLayer = true
            let backdrop = WindowMaterialView(frame: frame, images: images, videos: BackdropVideoPlayers())
            backdrop.autoresizingMask = [.width, .height]
            root.addSubview(backdrop)
            window.contentView = root
            window.orderFrontRegardless()
            let state = WindowBackdrop(tokens, selection: .art(art), legibility: legibility)
            backdrop.apply(state, tint: tokens.surfaceBackground.withAlpha(1).nsColor)
            let lines: [(String, ThemeRGB, CGFloat)] = [
                ("Primary text: the agent's reply reads here", tokens.textPrimary, 30),
                ("Secondary text: timestamps, file paths, captions", tokens.textSecondary, 24),
                ("Tertiary text: Add channel, hints, placeholders", tokens.textTertiary, 20),
            ]
            for (index, line) in lines.enumerated() {
                for column in 0..<2 {
                    let label = NSTextField(labelWithString: line.0)
                    label.font = .systemFont(ofSize: line.2, weight: index == 0 ? .semibold : .regular)
                    label.textColor = line.1.nsColor
                    label.frame = NSRect(x: 40 + CGFloat(column) * 600, y: 600 - CGFloat(index) * 70 - CGFloat(column) * 300,
                                         width: 1100, height: 44)
                    root.addSubview(label)
                }
            }
            root.layoutSubtreeIfNeeded()
            root.display()
            CATransaction.flush()
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
            let layer = try #require(root.layer)
            let scale = 2
            let ctx = try #require(CGContext(data: nil, width: Int(frame.width) * scale, height: Int(frame.height) * scale,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            layer.render(in: ctx)
            let image = try #require(ctx.makeImage())
            let url = URL(fileURLWithPath: out).appending(path: "glass-legibility-\(art.rawValue)-\(legibility.rawValue).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
            notes.append("\(legibility.rawValue): art \(art.rawValue), floor \(state.legibleTintOpacity), tint \(state.tintOpacity)")
        }
        }
        try notes.joined(separator: "\n").write(to: URL(fileURLWithPath: out).appending(path: "glass-legibility.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
