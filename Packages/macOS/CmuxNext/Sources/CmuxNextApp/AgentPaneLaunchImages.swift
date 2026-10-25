import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextWakeups

/// The agent panes' last pages, saved at quit and drawn under each pane at
/// launch until its live page paints, so a relaunch never shows an empty
/// agent pane (sweep 4a). One image per tab, named with its point scale; a
/// save replaces the whole set. Each image is handed out once per launch.
/// A JPEG or a PNG, as `CGImage.pageImageData` encodes it. A saved page is
/// read and decoded off the main thread (``takeSaved(_:on:)``).
@MainActor
final class AgentPaneLaunchImages {

    let directory: URL?
    /// Reads the saved pages.
    private let reader: LaunchFileReader
    private var taken: Set<String> = []
    /// Released pages' last frames (AgentPageHibernation), in memory as encoded images: a page built
    /// again draws its old frame until it paints, as at launch.
    private var held: [String: (data: Data, size: NSSize, appearance: NSAppearance.Name?)] = [:]
    init(directory: URL?, reader: LaunchFileReader = LaunchFileReader()) {
        self.directory = directory
        self.reader = reader
    }

    /// The directory next to the launch snapshot of `file` (the tag's state).
    convenience init(beside file: SidebarSnapshotFile?) {
        self.init(directory: file?.url.deletingLastPathComponent().appending(path: "agent-pane-images", directoryHint: .isDirectory))
    }

    /// A released page's frame (AgentPageHibernation, in memory), once, when the pane still has its
    /// size (zero: not laid out yet) and appearance: after a resize or a light/dark switch the pane
    /// shows its loading state instead. The page the last quit saved is ``takeSaved(_:on:)``'s.
    func take(_ key: String, size: NSSize = .zero, appearance: NSAppearance.Name? = nil) -> NSImage? {
        guard let frame = held.removeValue(forKey: key), frame.appearance == appearance, size == .zero || size == frame.size,
              let rep = NSBitmapImageRep(data: frame.data) else { return nil }
        let image = NSImage(size: frame.size)
        rep.size = frame.size
        image.addRepresentation(rep)
        return image
    }

    /// Whether `key` may have a saved page not asked for yet (no disk access: it may have none).
    func mayHaveSaved(_ key: String) -> Bool {
        directory != nil && Self.isFileSafe(key) && !taken.contains(key)
    }

    /// `key`'s saved page from the last quit at its point size, the first time it is asked for. The
    /// read (up to 8 MB) and the decode run on `work`'s files lane, never on the main thread.
    func takeSaved(_ key: String, on work: BackgroundWork) async -> NSImage? {
        guard let directory, Self.isFileSafe(key), taken.insert(key).inserted else { return nil }
        let reader = reader
        // A person waits for it: it is the pane's first frame of its page.
        guard let page = try? await work.run(.userBlocking, mayBlock: .files, { Self.read(key, in: directory, reader) }) else { return nil }
        return NSImage(cgImage: page.image, size: page.size)
    }

    /// `key`'s saved page, decoded, and its point size: either kind a save may have written (one at
    /// a time: a save replaces the set).
    private nonisolated static func read(_ key: String, in directory: URL, _ reader: LaunchFileReader) -> (image: CGImage, size: NSSize)? {
        for (scale, ext) in [2, 1, 3].flatMap({ scale in ["png", "jpg"].map { (scale, $0) } }) {
            let url = directory.appending(path: fileName(key, scale: scale, ext: ext))
            guard let page = reader.image(at: url, maximumBytes: maximumBytes) else { continue }
            return (page, NSSize(width: CGFloat(page.width) / CGFloat(scale), height: CGFloat(page.height) / CGFloat(scale)))
        }
        return nil
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
        guard let directory else { return }
        // NSImage stays on the main actor; the encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        for (key, image) in images where Self.isFileSafe(key) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else { continue }
            let scale = max(1, min(3, Int((CGFloat(cgImage.width) / image.size.width).rounded())))
            frames[Self.fileName(key, scale: scale, ext: cgImage.pageImageExtension)] = cgImage
        }
        await Task.detached { Self.write(frames.compactMapValues { $0.pageImageData() }, to: directory) }.value
    }

    private nonisolated static func write(_ files: [String: Data], to directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where files[old] == nil {
            try? manager.removeItem(at: directory.appending(path: old))
        }
        for (name, data) in files {
            let url = directory.appending(path: name)
            guard (try? data.write(to: url, options: [.atomic])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A larger file is not read.
    nonisolated static let maximumBytes = 8 << 20

    private nonisolated static func fileName(_ key: String, scale: Int, ext: String) -> String { "\(key)@\(scale)x.\(ext)" }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    private nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
