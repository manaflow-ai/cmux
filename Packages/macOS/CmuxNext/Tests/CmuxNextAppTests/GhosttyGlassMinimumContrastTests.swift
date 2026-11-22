import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import GhosttyNextKit
import IOSurface
import Testing

/// cx-cvj2a: with a macOS glass background (`background-blur = macos-glass-regular`) Ghostty
/// leaves the background to the window's glass and draws text over a transparent frame. With
/// `minimum-contrast` above 1 on a light theme, dark text must stay dark: it sits on the light
/// background, not on black. Renders a real Ghostty surface and reads the frame it presents.
///
/// cx-d07pp: a translucent window without glass (`background-opacity` below 1) takes the same
/// path, because the surfaces draw a transparent default background there
/// (`GhosttyRuntimeSurfacePolicy`) and the host paints the background.
@MainActor @Suite(.serialized, .closesItsWindows) struct GhosttyGlassMinimumContrastTests {
    @Test func darkTextOnALightGlassThemeStaysDark() async throws {
        // Flexoki Light's colors.
        let result = try await Self.renderText(config: """
        background = #fffcf0
        foreground = #100f0f
        minimum-contrast = 2
        background-blur = macos-glass-regular

        """)
        #expect(result.count > 50, "expected rendered text pixels, found \(result.count)")
        // Ghostty skipped its own background fill: the glass owns it.
        #expect(result.transparentFraction > 0.5,
                "only \(result.transparentFraction) of the frame was transparent; the glass background was not active")
        #expect(result.meanLuminance < 0.5,
                "dark text rendered with mean luminance \(result.meanLuminance) on a light glass background")
    }

    @Test func darkTextOnALightTranslucentThemeStaysDark() async throws {
        // A translucent window with no blur, through the policy a user's config gets.
        let opacity = 0.8
        let policy = try #require(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: opacity, opacityCells: false),
                                  "a translucent window keeps the surface background")
        let result = try await Self.renderText(config: """
        background = #fffcf0
        foreground = #100f0f
        minimum-contrast = 2
        background-opacity = \(opacity)
        \(policy)

        """)
        #expect(result.count > 50, "expected rendered text pixels, found \(result.count)")
        // Ghostty skipped its own background fill: the window root paints it.
        #expect(result.transparentFraction > 0.5,
                "only \(result.transparentFraction) of the frame was transparent; the surface background was drawn")
        #expect(result.meanLuminance < 0.5,
                "dark text rendered with mean luminance \(result.meanLuminance) on a light translucent background")
    }

    /// Renders six rows of text in a real Ghostty surface with `config` and samples the frame
    /// it presents.
    static func renderText(config text: String) async throws -> TextPixelSample {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        // A fresh config keeps the runner's own Ghostty config out.
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(config)
        let theme = GhosttyThemeConfig(config: config, themeName: "cmux-next-test", colors: nil)

        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        // Draw even when the runner's window is not on screen, as a hover mirror does.
        session.mirrorDemand = 1
        session.setTheme(theme)
        window.orderFrontRegardless()

        let line = String(repeating: "M", count: 40)
        io.send(.output(Data(("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + Array(repeating: line, count: 6).joined(separator: "\r\n")).utf8)))

        // Frames drawn before the config lands use the old colors, so wait for dark text
        // instead of sampling the first frame.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var sample: TextPixelSample?
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            sample = Self.textPixels(session.surfaceView.presentedFrame)
            if let sample, sample.count > 50, sample.meanLuminance < 0.5, sample.transparentFraction > 0.5 { break }
        }
        return try #require(sample, "Ghostty presented no IOSurface frame")
    }

    struct TextPixelSample {
        var count: Int
        var meanLuminance: Double
        var transparentFraction: Double
    }

    /// Mean luminance of the mostly opaque pixels of a presented frame (32BGRA, premultiplied).
    /// The frame is transparent except for text, because the host owns the background.
    static func textPixels(_ surface: IOSurface?) -> TextPixelSample? {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 0 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var count = 0
        var transparent = 0
        var luminance = 0.0
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let pixel = bytes + y * surface.bytesPerRow + x * 4
                if pixel[3] == 0 { transparent += 1 }
                let alpha = Double(pixel[3])
                guard alpha >= 160 else { continue }
                let blue = Double(pixel[0]) / alpha
                let green = Double(pixel[1]) / alpha
                let red = Double(pixel[2]) / alpha
                luminance += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                count += 1
            }
        }
        let transparentFraction = Double(transparent) / Double(surface.width * surface.height)
        return TextPixelSample(count: count, meanLuminance: count > 0 ? luminance / Double(count) : 1,
                               transparentFraction: transparentFraction)
    }
}
