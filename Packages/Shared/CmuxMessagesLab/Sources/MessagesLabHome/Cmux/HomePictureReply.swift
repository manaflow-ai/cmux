import AppKit
import ImageIO
import UniformTypeIdentifiers

/// cmux: how a marked-up picture leaves the large picture viewer: as a PNG file (Home's media folder, named by
/// time), handed to the chat's attachment intake on a private pasteboard, the same path as a paste of a picture
/// file, so the user's clipboard is never touched.
struct HomePictureReply {
    /// The folder the exported pictures go to.
    var directory: URL

    init(directory: URL = HomeMedia.directory.appendingPathComponent("annotated", isDirectory: true)) {
        self.directory = directory
    }

    /// Writes `image` as a PNG named after `title`; nil when it could not be written.
    func write(_ image: CGImage, title: String) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let stamp = Int(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0
        let url = directory.appendingPathComponent("\(safe.isEmpty ? "picture" : String(safe.prefix(40)))-marked-\(stamp).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// A private pasteboard carrying the file `url` (release it once the intake read it).
    static func pasteboard(for url: URL) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects([url as NSURL])
        return board
    }
}
