import AppKit

/// The agent panes' last pages, saved at quit and drawn under each pane at
/// launch until its live page paints, so a relaunch never shows an empty
/// agent pane (sweep 4a). One JPEG per tab, named with its point scale; a
/// save replaces the whole set. Each image is handed out once per launch.
@MainActor
final class AgentPaneLaunchImages {
    static let directoryName = "agent-pane-images"
    /// A larger file is not read.
    static let maximumBytes = 8 * 1024 * 1024

    let directory: URL?
    private var taken: Set<String> = []

    init(directory: URL?) {
        self.directory = directory
    }

    /// The directory next to the launch snapshot of `file` (the tag's state).
    convenience init(beside file: SidebarSnapshotFile?) {
        self.init(directory: file?.url.deletingLastPathComponent().appending(path: Self.directoryName, directoryHint: .isDirectory))
    }

    /// `key`'s saved page at its point size, the first time it is asked for.
    func take(_ key: String) -> NSImage? {
        guard let directory, Self.isFileSafe(key), taken.insert(key).inserted else { return nil }
        for scale in [2, 1, 3] {
            let url = directory.appending(path: Self.fileName(key, scale: scale))
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
                  // concurrency-allow: one capped read of a small local image before the agent pane's first frame
                  let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / CGFloat(scale), height: CGFloat(rep.pixelsHigh) / CGFloat(scale)))
            rep.size = image.size
            image.addRepresentation(rep)
            return image
        }
        return nil
    }

    /// Replaces the saved pages with `images` (by tab key).
    func save(_ images: [String: NSImage]) async {
        guard let directory else { return }
        var files: [String: Data] = [:]
        for (key, image) in images where Self.isFileSafe(key) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else { continue }
            let scale = max(1, min(3, Int((CGFloat(cgImage.width) / image.size.width).rounded())))
            guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }
            files[Self.fileName(key, scale: scale)] = data
        }
        await Task.detached { Self.write(files, to: directory) }.value
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

    private nonisolated static func fileName(_ key: String, scale: Int) -> String { "\(key)@\(scale)x.jpg" }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    private nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
