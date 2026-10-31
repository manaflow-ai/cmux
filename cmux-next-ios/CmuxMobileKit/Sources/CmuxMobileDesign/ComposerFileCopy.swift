import Foundation

/// A provider's URL expires after its callback. Preserve a disk copy before
/// returning; large files never become a Data. The system reclaims temporary
/// copies just as it does the composer’s picked movies and file previews.
public struct ComposerFileCopy: Sendable {
    public let url: URL
    public let byteCount: Int
    public let inlineData: Data?
    public static let inlineBytes = 256 << 10

    public init(source: URL, name: String? = nil, inlineLimit: Int = Self.inlineBytes) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paste-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent((name ?? source.lastPathComponent).replacingOccurrences(of: "/", with: "-"))
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            byteCount = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            inlineData = byteCount <= inlineLimit ? try handle.read(upToCount: inlineLimit) ?? Data() : nil
            url = destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
