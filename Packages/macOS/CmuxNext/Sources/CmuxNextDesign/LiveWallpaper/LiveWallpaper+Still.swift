public import CoreGraphics
public import CmuxTheme

extension LiveWallpaper {
    /// The wallpaper's still in `tokens`' colors at `width` x `height` pixels: one frame drawn off
    /// screen at the manifest's still time and pointer (the picker's thumbnail, the light field's
    /// picture). Nil without a GPU or when its program does not build. The program builds off the
    /// main thread in `programs` and the GPU's completion resumes the read, so no thread waits. A
    /// motion scene draws through the same pipeline: a fresh player packs its Scene block at the
    /// still's time, and its badge (this Mac's user) is drawn off the main thread.
    public func still(width: Int, height: Int, tokens: ThemeTokens, programs: LiveWallpaperPrograms) async -> CGImage? {
        guard width > 0, height > 0, let pipeline = await programs.pipeline(for: self) else { return nil }
        let colors = LiveWallpaperColors(tokens)
        let frame = LiveWallpaperFrame.still(self, width: width, height: height, colors: colors)
        var scene: LiveWallpaperSceneInputs?
        if isScene {
            guard let inputs = await stillScene(frame, colors: colors) else { return nil }
            scene = inputs
        }
        return await LiveWallpaperRenderer.still(frame.packed(), scene: scene, pipeline: pipeline, width: width, height: height)
    }

    /// A scene's block for `frame` and its badge, when it shows one.
    private func stillScene(_ frame: LiveWallpaperFrame, colors: LiveWallpaperColors) async -> LiveWallpaperSceneInputs? {
        var block: [Float] = []
        let (evaluated, hasImage): (Bool, Bool) = {
            guard let player = makeScenePlayer() else { return (false, false) }
            // A fresh world lays itself out on its first step: the still shows the scene's resting layout.
            return (player.evaluate(frame, now: Double(frame.time), into: &block), player.hasImage)
        }()
        guard evaluated else { return nil }
        let image = hasImage ? await LiveWallpaperBadge(identity: .macUser, colors: colors).sceneImage() : nil
        return LiveWallpaperSceneInputs(block: block, image: image)
    }

    /// A key for a still of this wallpaper in `tokens`' colors: its id, program and colors.
    public nonisolated func stillKey(tokens: ThemeTokens) -> String {
        "\(id)|\(String(sourceDigest, radix: 16))|\(LiveWallpaperColors(tokens).key)"
    }
}
