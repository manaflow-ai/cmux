import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Pixel parity with Ghostty, on screen (user, Nov 17: "colors between ghostty and cmux-next are definitely still
/// different ... have tests so there will be no regressions"). A real libghostty surface draws ANSI, truecolor,
/// inverse and default-background cells in a window, the window server composites it, and every sampled cell must be
/// the color Ghostty draws for the config (its theme's background, foreground and palette, a truecolor cell its own
/// value) within 2/255 per channel in sRGB: Ghostty 1.4.0 itself lands within 1/255 of them (Display P3 round trip,
/// cmux-lawrence-2). It runs plain and over a background picture, where the terminal used to show the picture at the
/// window's tint instead of its own background (`TerminalGhosttyBackgroundOverArtTests`). A picture is stood in by a
/// mid-gray layer under the terminal: what a see-through terminal would show.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalGhosttyPixelParityTests {
    /// The largest channel step allowed, in 0...255 sRGB.
    nonisolated static let tolerance = 2
    /// The step allowed for a fully saturated primary: on the edge of the sRGB gamut the window server's Display P3
    /// round trip moves a channel by up to 3 (`#00ff00` reads `[3, 255, 0]` on a fleet mini's display in the plain
    /// window too, where nothing of cmux's lies over the cells); a see-through terminal's default background is off by
    /// far more (88/255 over mid-gray).
    nonisolated static let gamutEdgeTolerance = 4

    private struct Swatch {
        var name: String
        var row: Int
        var column: Int
        var expected: [Int]
        var tolerance = TerminalGhosttyPixelParityTests.tolerance
    }

    /// The bytes the terminal draws, and the cells to sample with the colors Ghostty draws them in.
    private static func pattern(_ colors: GhosttyThemeColors) -> (bytes: Data, swatches: [Swatch]) {
        func rgb(_ c: GhosttyThemeColors.RGB) -> [Int] { [Int(c.r), Int(c.g), Int(c.b)] }
        var text = "\u{1b}[?25l\u{1b}[H\u{1b}[2J"
        var swatches: [Swatch] = []
        // Row 0: palette 0-15 as backgrounds; row 1: as full-block foregrounds. Four cells each, sampled in the second.
        for index in 0..<16 { text += "\u{1b}[48;5;\(index)m    " }
        text += "\u{1b}[0m\r\n"
        for index in 0..<16 { text += "\u{1b}[38;5;\(index)m\u{2588}\u{2588}\u{2588}\u{2588}" }
        text += "\u{1b}[0m\r\n"
        for (index, color) in colors.palette.prefix(16).enumerated() {
            swatches.append(Swatch(name: "bg \(index)", row: 0, column: index * 4 + 1, expected: rgb(color)))
            swatches.append(Swatch(name: "fg \(index)", row: 1, column: index * 4 + 1, expected: rgb(color)))
        }
        // Row 2: truecolor backgrounds.
        let truecolors = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [128, 128, 128], [255, 255, 255], [0, 0, 0], [39, 40, 34]]
        for (index, color) in truecolors.enumerated() {
            text += "\u{1b}[48;2;\(color[0]);\(color[1]);\(color[2])m    "
            let primary = color.allSatisfy { $0 == 0 || $0 == 255 } && Set(color).count > 1
            swatches.append(Swatch(name: "truecolor \(color)", row: 2, column: index * 4 + 1, expected: color,
                                   tolerance: primary ? Self.gamutEdgeTolerance : Self.tolerance))
        }
        text += "\u{1b}[0m\r\n"
        // Row 3: inverse default (the foreground as a background), then the default foreground as a full block.
        text += "\u{1b}[7m    \u{1b}[0m\u{2588}\u{2588}\u{2588}\u{2588}\r\n"
        swatches.append(Swatch(name: "inverse default", row: 3, column: 1, expected: rgb(colors.foreground)))
        swatches.append(Swatch(name: "default fg", row: 3, column: 5, expected: rgb(colors.foreground)))
        // The default background: an empty row, near and far.
        swatches.append(Swatch(name: "default bg", row: 5, column: 3, expected: rgb(colors.background)))
        swatches.append(Swatch(name: "default bg far", row: 7, column: 40, expected: rgb(colors.background)))
        return (Data(text.utf8), swatches)
    }

    /// `image` drawn into an sRGB bitmap: the window server gives the display's color space.
    private static func srgbPixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }

    /// The median color of the middle half of cell (`row`, `column`); nil off the image.
    private static func sample(_ pixels: (bytes: [UInt8], width: Int, height: Int), origin: CGPoint, cell: CGSize,
                               row: Int, column: Int) -> [Int]? {
        let left = origin.x + CGFloat(column) * cell.width, top = origin.y + CGFloat(row) * cell.height
        let xs = Int((left + cell.width * 0.25).rounded())..<Int((left + cell.width * 0.75).rounded())
        let ys = Int((top + cell.height * 0.25).rounded())..<Int((top + cell.height * 0.75).rounded())
        guard xs.lowerBound >= 0, ys.lowerBound >= 0, xs.upperBound <= pixels.width, ys.upperBound <= pixels.height,
              !xs.isEmpty, !ys.isEmpty else { return nil }
        var channels: [[Int]] = [[], [], []]
        for y in ys { for x in xs {
            let offset = (y * pixels.width + x) * 4
            for channel in 0..<3 { channels[channel].append(Int(pixels.bytes[offset + channel])) }
        } }
        return channels.map { $0.sorted()[$0.count / 2] }
    }

    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() },
          arguments: [false, true])
    func everyCellIsTheColorGhosttyDraws(overPicture: Bool) async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        try #require(GhosttyConfigBackground.loaded.opacity >= 1, "this host's Ghostty config is see-through: Ghostty shows what is behind it too")
        let colors = try #require(GhosttyRuntime.shared.themeColors, "libghostty loaded no config")
        try #require(colors.palette.count >= 16)
        let io = ParityScriptedIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { io.finish(); session.view.removeFromSuperview(); window.close() }
        let scope = ThemeScope(level: .room)
        scope.pinBackdrop(overPicture ? .selection(.art(.dahlDresdenMoonlight)) : .none)
        let root = NSView(frame: window.contentLayoutRect)
        root.wantsLayer = true
        // The picture's stand-in: what a see-through terminal shows.
        if overPicture { root.layer?.backgroundColor = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
        window.contentView = root
        scope.root(root)
        session.view.frame = root.bounds
        root.addSubview(session.view)
        // Draw whatever the runner's window server says of the window's occlusion.
        session.mirrorDemand = 1
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.status(.connected))
        // The pattern goes out once the surfaces have the config the window asks for: over a picture the host is
        // see-through and they reload with a transparent default background (`GhosttyRuntime.setSeeThrough`), so
        // every frame with the pattern is drawn as the person sees it.
        let loaded = ContinuousClock.now + .seconds(5)
        while GhosttyRuntime.seeThroughLoaded != overPicture, ContinuousClock.now < loaded {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(GhosttyRuntime.seeThroughLoaded == overPicture, "the surfaces never loaded the \(overPicture ? "see-through" : "opaque") config")
        let (bytes, swatches) = Self.pattern(colors)
        io.send(.output(bytes))

        // The frame with the pattern; then more passes for the window server.
        let scale = window.backingScaleFactor
        var mismatches: [String] = []
        var waiting = "nothing yet"
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            try await Task.sleep(for: .milliseconds(100))
            if ContinuousClock.now > deadline {
                if mismatches.isEmpty { Issue.record("no frame of the terminal came on screen: \(waiting)") }
                break
            }
            session.view.layoutSubtreeIfNeeded()
            guard session.surfaceView.presentedFrame != nil else { waiting = "the terminal presented no frame"; continue }
            let cellPixels = session.model.cellPixelSize
            guard cellPixels.width > 0, cellPixels.height > 0 else { waiting = "the terminal has no cell size"; continue }
            let image: CGImage
            do { image = try await window.screenshotImage() } catch { waiting = "the window capture failed: \(error)"; continue }
            guard let pixels = Self.srgbPixels(image) else { waiting = "the capture did not convert to sRGB"; continue }
            // Image pixels per cell: the image is the window at its backing scale (the host fills it).
            let ratio = CGFloat(pixels.width) / (window.frame.width * scale)
            let cell = CGSize(width: cellPixels.width * ratio, height: cellPixels.height * ratio)
            let first = session.view.firstCellOrigin
            let origin = CGPoint(x: first.x * scale * ratio, y: first.y * scale * ratio)
            mismatches = swatches.compactMap { swatch in
                guard let got = Self.sample(pixels, origin: origin, cell: cell, row: swatch.row, column: swatch.column) else {
                    return "\(swatch.name): off the image"
                }
                let delta = zip(got, swatch.expected).map { abs($0 - $1) }.max() ?? 0
                return delta > swatch.tolerance ? "\(swatch.name): expected \(swatch.expected), got \(got) (\(delta)/255)" : nil
            }
            if mismatches.isEmpty { break }
            waiting = "cells differ"
        }
        #expect(mismatches.isEmpty, "\(overPicture ? "over a picture" : "plain"): \(mismatches.count) of \(swatches.count) cells differ from Ghostty: \(mismatches.joined(separator: "; "))")
    }
}

/// A scripted ``TerminalIO``: the test sends its events.
private nonisolated final class ParityScriptedIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}
