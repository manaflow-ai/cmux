import AppKit

struct TerminalInlineImageThumbnail: Sendable {
    let cgImage: CGImage
    let pixelSize: CGSize
    let cost: Int
}
