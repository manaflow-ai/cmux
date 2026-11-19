// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxRemoteComputerUse

/// The agent cursor drawn offscreen, at 2x, in every interaction: checks it renders sharp and in
/// cmux blue, and writes each state as a PNG to `CMUX_CURSOR_RENDER_DIR` when set (the detail
/// catalog's images).
@MainActor
@Suite struct AgentCursorRenderTests {
    static let size = CGSize(width: 360, height: 220)
    static let window = CGRect(x: 40, y: 30, width: 280, height: 160)
    static let backdrop: [(CGRect, NSColor)] = [
        (CGRect(origin: .zero, size: size), NSColor(white: 0.93, alpha: 1)),
        (window, NSColor.white),
        (CGRect(x: window.minX, y: window.minY, width: window.width, height: 22), NSColor(white: 0.86, alpha: 1)),
    ]

    static func event(_ kind: AgentCursorEvent.Kind, at: CGPoint? = CGPoint(x: 150, y: 90), text: String = "",
                      button: String = "left", count: Int = 1) -> AgentCursorEvent {
        var e = AgentCursorEvent(kind: kind, session: "s", label: "Claude Code", at: at, text: text)
        e.button = button
        e.count = count
        return e
    }

    static var states: [(String, [AgentCursorEvent], String)] {
        var scroll = event(.scroll)
        scroll.scroll = CGVector(dx: 0, dy: 3)
        var scrollUp = event(.scroll)
        scrollUp.scroll = CGVector(dx: 0, dy: -3)
        var scrollRight = event(.scroll)
        scrollRight.scroll = CGVector(dx: 4, dy: 0)
        var drag = event(.drag, at: CGPoint(x: 250, y: 150))
        drag.from = CGPoint(x: 120, y: 80)
        var look = event(.look, at: CGPoint(x: 180, y: 110))
        look.rect = window
        return [
            ("01-rest", [event(.move)], "Claude Code"),
            ("02-rest-long-name", [event(.move)], "Codex in cmux-cu-rewrite workspace"),
            ("03-click", [event(.click)], "Claude Code"),
            ("04-double-click", [event(.click, count: 2)], "Claude Code"),
            ("05-triple-click", [event(.click, count: 3)], "Claude Code"),
            ("06-right-click", [event(.click, button: "right")], "Claude Code"),
            ("07-middle-click", [event(.click, button: "middle")], "Claude Code"),
            ("08-typing", [event(.typing, text: "Ada Lovelace")], "Claude Code"),
            ("09-typing-long", [event(.typing, text: "a much longer sentence the agent types into the field")], "Claude Code"),
            ("10-keys-return", [event(.keys, text: "Return")], "Claude Code"),
            ("11-keys-cmd-shift-s", [event(.keys, text: "cmd+shift+s")], "Claude Code"),
            ("12-keys-ctrl-alt-tab", [event(.keys, text: "ctrl+alt+Tab")], "Claude Code"),
            ("13-scroll-down", [scroll], "Claude Code"),
            ("14-scroll-up", [scrollUp], "Claude Code"),
            ("15-scroll-right", [scrollRight], "Claude Code"),
            ("16-drag", [drag], "Claude Code"),
            ("17-look", [look], "Claude Code"),
            ("18-no-name", [event(.move)], ""),
        ]
    }

    /// The agent waits for the person (amber) and a refused step (red): drawn at 2x, the pointer
    /// takes the alert's color.
    static var alertStates: [(String, [AgentCursorEvent], (Int, Int, Int))] {
        [
            ("19-paused", [event(.move), event(.paused)], (0xFF, 0x9F, 0x0A)),
            ("20-refused", [event(.move), event(.refused, at: nil, text: "App is on the deny list")], (0xFF, 0x45, 0x3A)),
        ]
    }

    @Test func pausedAndRefusedRenderInTheirColors() throws {
        let dir = ProcessInfo.processInfo.environment["CMUX_CURSOR_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, events, rgb) in Self.alertStates {
            let image = try #require(AgentCursorOverlay.render(events, label: "Claude Code", size: Self.size, scale: 2,
                                                               backdrop: Self.backdrop), "\(name)")
            let px = Self.pixels(image)
            var hits = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 200 {
                if abs(Int(px[i]) - rgb.0) < 18, abs(Int(px[i + 1]) - rgb.1) < 18, abs(Int(px[i + 2]) - rgb.2) < 18 { hits += 1 }
            }
            #expect(hits > 150, "\(name): \(hits) pixels in the alert color")
            if let dir {
                let url = dir.appendingPathComponent("\(name).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }

    @Test func theTrailIsLongerForLongerMoves() throws {
        let dir = ProcessInfo.processInfo.environment["CMUX_CURSOR_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let size = CGSize(width: 560, height: 260)
        // Both moves end at the same point, so the pointer and its name tag cover the same pixels.
        let end = CGPoint(x: 300, y: 150)
        let short = try #require(AgentCursorOverlay.renderTrail(label: "Claude Code", size: size, scale: 2,
                                                               from: CGPoint(x: 240, y: 130), to: end))
        let long = try #require(AgentCursorOverlay.renderTrail(label: "Claude Code", size: size, scale: 2,
                                                              from: CGPoint(x: 20, y: 20), to: end))
        // A longer move leaves more trail behind it.
        #expect(Self.bluishPixels(long) > Self.bluishPixels(short) + 200)
        if let dir {
            for (name, image) in [("22-trail-short", short), ("23-trail-long", long)] {
                let url = dir.appendingPathComponent("\(name).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }

    @Test func theSpotlightAndTailRender() throws {
        let dir = ProcessInfo.processInfo.environment["CMUX_CURSOR_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let image = try #require(AgentCursorOverlay.renderSpotlight(label: "Claude Code", size: Self.size, scale: 2,
                                                                    at: CGPoint(x: 150, y: 90), backdrop: Self.backdrop))
        #expect(Self.bluePixels(image) > 400, "rings and pointer in cmux blue")
        if let dir {
            let url = dir.appendingPathComponent("21-show-cursor.png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }

    @Test func everyInteractionRendersSharpInCmuxBlue() throws {
        let dir = ProcessInfo.processInfo.environment["CMUX_CURSOR_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, events, label) in Self.states {
            let image = try #require(AgentCursorOverlay.render(events, label: label, size: Self.size, scale: 2,
                                                               backdrop: Self.backdrop), "\(name)")
            // 2x: every point is two pixels.
            #expect(image.width == Int(Self.size.width * 2) && image.height == Int(Self.size.height * 2))
            #expect(Self.bluePixels(image) > 150, "\(name): the pointer is cmux blue")
            if let dir {
                let url = dir.appendingPathComponent("\(name).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }

    @Test func thePointersEdgeIsAntialiasedAtRetinaDensity() throws {
        let image = try #require(AgentCursorOverlay.render([Self.event(.move)], label: "", size: Self.size, scale: 2))
        // A 1x layer upscaled has 2x2 blocks of equal pixels along its edge; a 2x layer has
        // intermediate alpha values on single pixels. Count distinct alpha levels on the edge.
        let levels = Self.alphaLevels(image)
        #expect(levels > 12, "alpha levels on the pointer's edge: \(levels)")
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    /// Pixels with any visible blue tint (the faint trail included).
    static func bluishPixels(_ image: CGImage) -> Int {
        let p = pixels(image)
        var n = 0
        for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 8 && Int(p[i + 2]) > Int(p[i]) + 12 {
            n += 1
        }
        return n
    }

    static func bluePixels(_ image: CGImage) -> Int {
        let p = pixels(image)
        var n = 0
        for i in stride(from: 0, to: p.count, by: 4) where abs(Int(p[i]) - 0x0A) < 24 && abs(Int(p[i + 1]) - 0x84) < 24 && p[i + 2] > 0xE0 {
            n += 1
        }
        return n
    }

    static func alphaLevels(_ image: CGImage) -> Int {
        let p = pixels(image)
        var levels = Set<UInt8>()
        for i in stride(from: 3, to: p.count, by: 4) where p[i] > 0 && p[i] < 255 { levels.insert(p[i]) }
        return levels.count
    }
}
