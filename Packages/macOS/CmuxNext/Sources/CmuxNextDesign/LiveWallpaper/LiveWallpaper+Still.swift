public import CoreGraphics
public import CmuxTheme

extension LiveWallpaper {
    /// The wallpaper's still in `tokens`' colors at `width` x `height` pixels: one frame drawn off
    /// screen at the manifest's still time and pointer (the picker's thumbnail, the light field's
    /// picture). Nil without a GPU or when its program does not build. The program builds off the
    /// main thread in `programs` and the GPU's completion resumes the read, so no thread waits.
    public func still(width: Int, height: Int, tokens: ThemeTokens, programs: LiveWallpaperPrograms) async -> CGImage? {
        guard width > 0, height > 0, let pipeline = await programs.pipeline(for: self) else { return nil }
        let uniform = LiveWallpaperFrame.still(self, width: width, height: height, colors: LiveWallpaperColors(tokens)).packed()
        return await LiveWallpaperRenderer.still(uniform, pipeline: pipeline, width: width, height: height)
    }

    /// A key for a still of this wallpaper in `tokens`' colors: its id, program and colors.
    public nonisolated func stillKey(tokens: ThemeTokens) -> String {
        "\(id)|\(String(sourceDigest, radix: 16))|\(LiveWallpaperColors(tokens).key)"
    }
}
