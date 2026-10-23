import AppKit
import CmuxNextAgentPane

/// The agent panes' last pages, saved at quit and drawn under each pane at
/// launch until its live page paints, so a relaunch never shows an empty
/// agent pane (sweep 4a). One image per tab, named with its point scale; a
/// save replaces the whole set. Each image is handed out once per launch.
/// A JPEG or a PNG, as `CGImage.pageImageData` encodes it.
@MainActor
final class AgentPaneLaunchImages {

    let directory: URL?
    private var taken: Set<String> = []
    /// Released pages' last frames (AgentPageHibernation), in memory as encoded images: a page built
    /// again draws its old frame until it paints, as at launch.
    private var held: [String: (data: Data, size: NSSize, appearance: NSAppearance.Name?)] = [:]
    init(directory: URL?) {
        self.directory = directory
    }

    /// The directory next to the launch snapshot of `file` (the tag's state).
    convenience init(beside file: SidebarSnapshotFile?) {
        self.init(directory: file?.url.deletingLastPathComponent().appending(path: "agent-pane-images", directoryHint: .isDirectory))
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
        guard let directory, Self.isFileSafe(key), taken.insert(key).inserted else { return nil }
        // Either kind a save may have written (one at a time: a save replaces the set).
        for (scale, ext) in [2, 1, 3].flatMap({ scale in ["png", "jpg"].map { (scale, $0) } }) {
            let url = directory.appending(path: Self.fileName(key, scale: scale, ext: ext))
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8 << 20 /* a larger file is not read */,
                  // concurrency-allow: one capped read of a small local image before the agent pane's first frame
                  let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            // #17587's launch guard counts a read on the main thread.
            DebugTimings.markLaunch("launch_read_on_main.agent_page_images")
            let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / CGFloat(scale), height: CGFloat(rep.pixelsHigh) / CGFloat(scale)))
            rep.size = image.size
            image.addRepresentation(rep)
            return image
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

    private nonisolated static func fileName(_ key: String, scale: Int, ext: String) -> String { "\(key)@\(scale)x.\(ext)" }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    private nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
