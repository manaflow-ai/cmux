public import AppKit

/// Saves what is dropped on a grid into its folder: dropped files are
/// copied in (never moved; the source keeps its file), and picture data
/// with no file (a picture dragged out of a web page or an editor) becomes
/// a PNG named for the time it was dropped. A name already taken gets the
/// next free number.
public nonisolated struct FileGridDropImporter: Sendable {
    private let naming: FileGridNaming
    private let now: @Sendable () -> Date

    /// Makes an importer.
    ///
    /// - Parameters:
    ///   - naming: the free-name rule (default: the disk's).
    ///   - now: the clock that names saved picture data.
    public init(naming: FileGridNaming = FileGridNaming(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.naming = naming
        self.now = now
    }

    /// Whether `drop` holds anything this importer saves.
    ///
    /// - Parameter drop: the drag's pasteboard (or a test value).
    @MainActor
    public func canImport(_ drop: any FileGridDropContents) -> Bool {
        !drop.droppedFileURLs.isEmpty || drop.holdsImage
    }

    /// Saves the drop's files or picture into `folder`.
    ///
    /// - Parameters:
    ///   - drop: the drag's pasteboard (or a test value).
    ///   - folder: where they go.
    /// - Returns: the new files.
    /// - Throws: the first copy or write error (earlier files stay saved).
    @MainActor
    @discardableResult
    public func importItems(from drop: any FileGridDropContents, into folder: URL) throws -> [URL] {
        let manager = FileManager()
        let files = drop.droppedFileURLs
        if !files.isEmpty {
            var saved: [URL] = []
            for file in files where file.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                let target = naming.free(file.lastPathComponent, in: folder)
                try manager.copyItem(at: file, to: target)
                saved.append(target)
            }
            return saved
        }
        guard let image = drop.droppedImage, let png = Self.pngData(image) else { return [] }
        let target = naming.free(Self.droppedName(at: now()), in: folder)
        try png.write(to: target, options: .withoutOverwriting)
        return [target]
    }

    /// `Dropped Image 2026-10-19 at 16.35.24.png`: the drop's local time, in the shape macOS names screenshots.
    ///
    /// - Parameter date: when it was dropped.
    public static func droppedName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Dropped Image \(formatter.string(from: date)).png"
    }

    @MainActor
    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
