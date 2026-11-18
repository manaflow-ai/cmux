import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import IOSurface
import Testing

/// A Ghostty `background-image` shows in a see-through cmux window (user, Nov 17: "we need to make sure custom bgs
/// work properly").
///
/// In a see-through window the window root paints the one translucent sheet, so cmux loads the surfaces with a
/// transparent default background (`GhosttyRuntimeSurfacePolicy`). Ghostty multiplies its background image by the
/// background's alpha (`bg_image_fragment`: "Multiply everything by the background color alpha"), so with that alpha
/// at 0 the image was never drawn. The image must show as Ghostty draws it at the window's opacity: the picture
/// scaled by `background-image-opacity` times `background-opacity`, its own color unchanged. The config goes through
/// cmux's own load (`GhosttyRuntime.loadConfig`), a real surface draws it, and the frame it presents is read.
@MainActor @Suite(.serialized, .closesItsWindows) struct GhosttyBackgroundImageSeeThroughTests {
    /// The image's one color, sRGB bytes.
    static let imageColor = [230, 77, 26]

    static func writeImage(in folder: URL) throws -> URL {
        let url = folder.appending(path: "bg.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<32 { for x in 0..<32 {
            var pixel = imageColor + [255]
            rep.setPixel(&pixel, atX: x, y: y)
        } }
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// The median premultiplied BGRA pixel of a presented frame, as sRGB-ish bytes `[r, g, b, a]`.
    static func median(_ surface: IOSurface?) -> [Int]? {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 0 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var channels: [[Int]] = [[], [], [], []]
        for y in stride(from: surface.height / 4, to: surface.height * 3 / 4, by: 3) {
            for x in stride(from: surface.width / 4, to: surface.width * 3 / 4, by: 3) {
                let pixel = bytes + y * surface.bytesPerRow + x * 4
                channels[0].append(Int(pixel[2])); channels[1].append(Int(pixel[1]))
                channels[2].append(Int(pixel[0])); channels[3].append(Int(pixel[3]))
            }
        }
        return channels.map { $0.sorted()[$0.count / 2] }
    }

    @Test(arguments: [1.0, 0.5])
    func aGhosttyBackgroundImageShowsInATranslucentWindow(imageOpacity: Double) async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gbi-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try Self.writeImage(in: folder)
        let windowOpacity = 0.85
        let file = folder.appending(path: "config")
        try """
        background = #202020
        background-opacity = \(windowOpacity)
        background-image = \(image.path)
        background-image-fit = stretch
        background-image-opacity = \(imageOpacity)

        """.write(to: file, atomically: true, encoding: .utf8)
        // cmux's load of the user's config records its values globally: put them back for the suites after.
        let (recorded, seeThrough) = (GhosttyConfigBackground.loaded, GhosttyRuntime.seeThroughLoaded)
        defer { GhosttyConfigBackground.loaded = recorded; GhosttyRuntime.seeThroughLoaded = seeThrough }
        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity, configFile: file.path),
                                  "cmux's config load made no config")
        try #require(abs(opacity - windowOpacity) < 0.001, "the window is not translucent at \(windowOpacity): \(opacity)")
        let theme = GhosttyThemeConfig(config: config, themeName: "cmux-next-test", colors: nil)

        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { io.finish(); window.close() }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        session.mirrorDemand = 1
        session.setTheme(theme)
        window.orderFrontRegardless()
        io.send(.output(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[H".utf8)))

        let alpha = Int((windowOpacity * imageOpacity * 255).rounded())
        let expected = Self.imageColor.map { Int((Double($0) * Double(alpha) / 255).rounded()) } + [alpha]
        func matches(_ got: [Int]) -> Bool { zip(got, expected).allSatisfy { abs($0 - $1) <= 4 } }
        var got: [Int] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            got = Self.median(session.surfaceView.presentedFrame) ?? []
            if matches(got) { break }
        }
        #expect(matches(got), "image at \(imageOpacity) in a window at \(windowOpacity): the surface presents \(got) (premultiplied r, g, b, a), Ghostty draws \(expected); diagnostics: \(diagnostics)")
    }
}
