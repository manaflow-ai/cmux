#if canImport(UIKit)
import CmuxAgentChat
import UIKit

/// Maps a fixture `ChatAttachment` to a local image URL, generating a
/// deterministic gradient PNG on first request. Fixtures carry no real URLs, so
/// this keeps media rendering offline and deterministic while still exercising
/// the real async pipeline (off-main decode, memory + disk cache, prefetch) the
/// way real network media would.
enum ChatLabMediaProvider {
    private static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-lab-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Resolves the on-disk URL for an attachment, materializing the image if
    /// needed. Returns nil for non-fixture or non-image attachments.
    static func url(for attachment: ChatAttachment) -> URL? {
        guard attachment.media == .image,
              let hostPath = attachment.hostPath,
              hostPath.hasPrefix("\(ChatLabFixture.mediaScheme):"),
              let seed = Int(hostPath.dropFirst(ChatLabFixture.mediaScheme.count + 1))
        else { return nil }

        let url = directory.appendingPathComponent("media-\(seed).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = render(seed: seed) else { return nil }
        try? data.write(to: url)
        return url
    }

    /// Deterministic gradient image keyed off the seed.
    private static func render(seed: Int) -> Data? {
        let size = CGSize(width: 1280, height: 860)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let hue = CGFloat((seed * 67) % 360) / 360
            let top = UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor
            let bottom = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top, bottom] as CFArray,
                locations: [0, 1]
            )
            if let gradient {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }
            let label = "screenshot \(seed)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 72),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            label.draw(at: CGPoint(x: 64, y: 64), withAttributes: attrs)
        }
        return image.pngData()
    }
}
#endif
