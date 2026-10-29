import CryptoKit
public import Foundation
public import CmuxNextAppearance

/// Full images of the art that does not ship in the app (cx-t2x.7): fetched once from
/// files.cmux.com by the SHA-256 the manifest records, kept in the backgrounds folder only when
/// the bytes match it, and read from there afterwards.
public actor BackdropArtDownloads {
    /// The app's downloads, in its Application Support folder.
    public static let shared = BackdropArtDownloads(folder: defaultFolder) { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Where the published images live, each named by its SHA-256.
    nonisolated static let remoteBase = URL(string: "https://files.cmux.com/cmux-art/")

    /// The backgrounds folder: `~/Library/Application Support/<bundle id>/Backgrounds`.
    public nonisolated static var defaultFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("Backgrounds", isDirectory: true)
    }

    private nonisolated let folder: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private var running: [String: Task<URL?, Never>] = [:]

    /// - Parameters:
    ///   - folder: Where downloads are kept; nil keeps none.
    ///   - fetch: Reads a URL's body (tests inject one).
    public init(folder: URL?, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.folder = folder
        self.fetch = fetch
    }

    /// The downloaded image of `id`, if it is here already.
    public nonisolated func cachedFile(id: String) -> URL? {
        guard let file = file(named: id), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// The image of `art`, downloading it first if needed; nil when that fails.
    public func file(for art: BackdropArt) async -> URL? {
        await file(id: art.rawValue, sha256: art.entry.sha256)
    }

    /// The image `id`, downloading the file named `sha256` first if needed; nil when the
    /// download fails or its bytes do not hash to `sha256`.
    public func file(id: String, sha256: String) async -> URL? {
        if let cached = cachedFile(id: id) { return cached }
        if let load = running[id] { return await load.value }
        guard let target = file(named: id), let remote = Self.remoteBase?.appendingPathComponent("\(sha256).avif") else {
            return nil
        }
        let fetch = fetch
        // task-owner: one download per id, shared by concurrent callers and cleared when done
        let load = Task<URL?, Never> {
            guard let data = try? await fetch(remote), Self.hex(SHA256.hash(data: data)) == sha256.lowercased() else {
                return nil
            }
            return Self.write(data, to: target) ? target : nil
        }
        running[id] = load
        let result = await load.value
        running[id] = nil
        return result
    }

    private nonisolated func file(named id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        return folder?.appendingPathComponent("\(id).avif")
    }

    private nonisolated static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes through a temporary file so a reader never sees half an image.
    private nonisolated static func write(_ data: Data, to file: URL) -> Bool {
        let folder = file.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(UUID().uuidString + ".partial")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: partial)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: partial)
            return true
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
    }
}
