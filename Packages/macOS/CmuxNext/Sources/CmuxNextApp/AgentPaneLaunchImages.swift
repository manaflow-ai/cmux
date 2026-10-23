import AppKit
import CmuxNextAgentPane
import CmuxNextDesign

/// The agent panes' last pages, saved at quit and drawn under each pane at
/// launch until its live page paints, so a relaunch never shows an empty
/// agent pane (sweep 4a). One image per tab, named with its point scale; a
/// save replaces the whole set. Each image is handed out once per launch.
/// A JPEG or a PNG, as `CGImage.pageImageData` encodes it. The files are read
/// and decoded off the main thread from the top of `main`
/// (`SavedFrameDirectory`, #17587), so a pane build only takes its decoded image.
@MainActor
final class AgentPaneLaunchImages {
    /// A larger file is not read.
    nonisolated static let maximumBytes = 8 << 20

    private let frames: SavedFrameDirectory
    /// Released pages' last frames (AgentPageHibernation), in memory as encoded images: a page built
    /// again draws its old frame until it paints, as at launch.
    private var held: [String: (data: Data, size: NSSize, appearance: NSAppearance.Name?)] = [:]

    /// The images of `frames`, the directory the launch began reading in `main`.
    init(frames: SavedFrameDirectory) {
        self.frames = frames
    }

    /// The images in `directory` (read from now on); nil keeps none. Tests and the no-launch
    /// fallback only: its reads report to no launch guard. The launch reads through ``init(frames:)``.
    convenience init(directory: URL?) {
        self.init(frames: SavedFrameDirectory(url: directory, maximumBytes: Self.maximumBytes, name: "agent_page_images", readOnMain: { _ in }))
    }

    /// The images' directory in `state`, the app's state directory (beside its sidebar snapshot).
    nonisolated static func directory(beside state: URL) -> URL {
        state.appending(path: "agent-pane-images", directoryHint: .isDirectory)
    }

    /// `key`'s saved page at its point size, the first time it is asked for. A released page's
    /// frame comes first, once, when the pane still has its size (zero: not laid out yet) and
    /// appearance: after a resize or a light/dark switch the pane shows its loading state instead.
    func take(_ key: String, size: NSSize = .zero, appearance: NSAppearance.Name? = nil) -> NSImage? {
        if let frame = held.removeValue(forKey: key), frame.appearance == appearance, size == .zero || size == frame.size,
           let rep = NSBitmapImageRep(data: frame.data) {
            let image = NSImage(size: frame.size)
            rep.size = frame.size
            image.addRepresentation(rep)
            return image
        }
        return frames.take(key)?.makeImage()
    }

    /// Holds `image` as tab `key`'s frame until ``take(_:)`` or ``drop(_:)``.
    func hold(_ key: String, _ frame: CGImage, size: NSSize, appearance: NSAppearance.Name?) async {
        guard size.width > 0 else { return }
        let data = await Task.detached { frame.pageImageData() }.value
        held[key] = data.map { ($0, size, appearance) }
    }

    /// The tab closed or showed its live page: its held frame goes.
    func drop(_ key: String) {
        held[key] = nil
    }

    /// Replaces the saved pages with `images` (by tab key).
    func save(_ images: [String: NSImage]) async {
        guard let directory = frames.url else { return }
        // NSImage stays on the main actor; the encode and the writes run detached.
        var encoded: [String: CGImage] = [:]
        for (key, image) in images where SavedFrameDirectory.isFileSafe(key) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else { continue }
            let scale = max(1, min(3, Int((CGFloat(cgImage.width) / image.size.width).rounded())))
            encoded[SavedFrameDirectory.fileName(key, scale: scale, ext: cgImage.pageImageExtension)] = cgImage
        }
        await Task.detached { SavedFrameDirectory.write(encoded.compactMapValues { $0.pageImageData() }, to: directory) }.value
    }
}
