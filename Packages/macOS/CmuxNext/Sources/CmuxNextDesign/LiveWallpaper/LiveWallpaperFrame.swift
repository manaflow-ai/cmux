import CCmuxWallpaperFFI
import CmuxTheme

/// The theme's colors as a live wallpaper gets them (`Frame.ink`, `.paper`, `.accent`), in linear
/// light (`cmux_wallpaper_srgb_to_linear`): ink is the theme's text color, paper its window
/// background, accent the app's accent.
nonisolated struct LiveWallpaperColors: Sendable, Hashable {
    var ink: SIMD3<Float>
    var paper: SIMD3<Float>
    var accent: SIMD3<Float>
    var dark: Bool

    init(_ tokens: ThemeTokens) {
        ink = Self.linear(tokens.textPrimary)
        paper = Self.linear(tokens.windowBackground)
        accent = Self.linear(tokens.accent)
        dark = tokens.isDark
    }

    private static func linear(_ color: ThemeRGB) -> SIMD3<Float> {
        SIMD3(cmux_wallpaper_srgb_to_linear(Float(color.red)), cmux_wallpaper_srgb_to_linear(Float(color.green)),
              cmux_wallpaper_srgb_to_linear(Float(color.blue)))
    }

    /// A stable key for a still drawn in these colors.
    var key: String {
        [ink, paper, accent].map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: "|") + (dark ? "|d" : "|l")
    }
}

/// One frame's values by name; ``packed()`` is the 36 floats of the 144-byte Frame uniform
/// (`cmux_wallpaper_frame_pack`, the one packer the gallery and the cover renderer share).
nonisolated struct LiveWallpaperFrame: Sendable {
    var time: Float = 0
    var delta: Float = 0
    var number: Float = 0
    /// The drawable's size in rendered pixels.
    var width: Float = 0
    var height: Float = 0
    /// Rendered pixels per point: the screen's backing scale times the render scale.
    var pixelsPerPoint: Float = 1
    var seed: Float = 0
    /// Rendered pixels, top left origin, and rendered pixels per second.
    var pointer = SIMD2<Float>(0, 0)
    var velocity = SIMD2<Float>(0, 0)
    var presence: Float = 0
    var sinceMoved: Float = 10_000
    var buttonDown = false
    var still = false
    var colors: LiveWallpaperColors
    var params: [Float] = []

    /// The Frame uniform: 36 floats.
    // perf-hot: 0.05ms live-wallpaper-frame (every drawn live wallpaper frame packs its uniform)
    func packed() -> [Float] {
        var input = CmuxWallpaperFrameInput()
        input.time = time
        input.delta = delta
        input.frame_number = number
        input.width = width
        input.height = height
        input.backing_scale = pixelsPerPoint
        input.seed = seed
        input.pointer_x = pointer.x
        input.pointer_y = pointer.y
        input.velocity_x = velocity.x
        input.velocity_y = velocity.y
        input.presence = presence
        input.since_moved = sinceMoved
        input.ink = (colors.ink.x, colors.ink.y, colors.ink.z)
        input.paper = (colors.paper.x, colors.paper.y, colors.paper.z)
        input.accent = (colors.accent.x, colors.accent.y, colors.accent.z)
        let p = params + Array(repeating: 0, count: max(0, 8 - params.count))
        input.params = (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
        input.still = still
        input.button_down = buttonDown
        input.dark = colors.dark
        var out = [Float](repeating: 0, count: Self.floats)
        out.withUnsafeMutableBufferPointer { buffer in
            withUnsafePointer(to: &input) { _ = cmux_wallpaper_frame_pack($0, buffer.baseAddress) }
        }
        return out
    }

    /// The Frame uniform's size in floats (nine `vec4<f32>`).
    static let floats = 36

    /// A still of `wallpaper` at `width` x `height` pixels: its `still` time and pointer, the pointer
    /// present and resting, in `colors`.
    static func still(_ wallpaper: LiveWallpaper, width: Int, height: Int, colors: LiveWallpaperColors) -> LiveWallpaperFrame {
        var frame = LiveWallpaperFrame(colors: colors)
        frame.time = wallpaper.stillTime
        frame.width = Float(width)
        frame.height = Float(height)
        frame.pixelsPerPoint = 1
        frame.seed = 0.5
        frame.pointer = SIMD2(wallpaper.stillPointer.x * Float(width), wallpaper.stillPointer.y * Float(height))
        frame.presence = 1
        frame.sinceMoved = 10
        frame.still = true
        frame.params = wallpaper.params
        return frame
    }
}
