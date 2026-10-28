public import AppKit
public import CmuxNextFileGrid
public import CmuxNextFiles

/// Saves what is dropped on the pane into a folder through CmuxNextFiles:
/// dropped files are copied in with ``FileOperating/transfer(_:to:mode:resolve:)``
/// (never moved; a taken name gets Finder's Keep Both number), and picture
/// data with no file (a picture dragged out of a web page or an editor)
/// becomes a PNG named for the time it was dropped.
@MainActor
public struct ScreenshotDropSaver {
    private let files: any FileOperating
    private let now: @Sendable () -> Date

    /// Makes a saver.
    ///
    /// - Parameters:
    ///   - files: the file operations (CmuxNextFiles' ``FileOperator`` on the app's files lane).
    ///   - now: the clock that names saved pictures.
    public init(files: any FileOperating, now: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files
        self.now = now
    }

    /// Whether `drop` holds anything this saver saves.
    ///
    /// - Parameter drop: the drag's pasteboard (or a test value).
    public func canSave(_ drop: any FileGridDropContents) -> Bool {
        !drop.droppedFileURLs.isEmpty || drop.holdsImage
    }

    /// Saves the drop's files or picture into `folder`. The drop is read before the first
    /// suspension, so a drag's pasteboard may be passed while the drop is being performed.
    ///
    /// - Parameters:
    ///   - drop: the drag's pasteboard (or a test value).
    ///   - folder: where they go.
    /// - Returns: the new files.
    /// - Throws: the copy's or the write's error.
    public func save(_ drop: any FileGridDropContents, into folder: URL) async throws -> [URL] {
        let urls = drop.droppedFileURLs
        if !urls.isEmpty { return try await copy(urls, into: folder) }
        guard let image = drop.droppedImage, let png = Self.pngData(image) else { return [] }
        return [try await files.newFile(in: folder, named: Self.droppedName(at: now()), contents: png)]
    }

    /// `Dropped Image 2026-10-19 at 16.35.24.png`: the drop's local time, in the shape macOS names screenshots.
    ///
    /// - Parameter date: when it was dropped.
    public nonisolated static func droppedName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Dropped Image \(formatter.string(from: date)).png"
    }

    private func copy(_ urls: [URL], into folder: URL) async throws -> [URL] {
        // A file from the destination itself is not copied onto itself.
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path }
        guard !sources.isEmpty else { return [] }
        var placed: [URL: URL] = [:]
        for try await event in files.transfer(sources, to: folder, mode: .copy, resolve: { _ in ConflictAnswer(.keepBoth, applyToAll: true) }) {
            if case .finished(let done, _) = event { placed = done }
        }
        return sources.compactMap { placed[$0] }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
