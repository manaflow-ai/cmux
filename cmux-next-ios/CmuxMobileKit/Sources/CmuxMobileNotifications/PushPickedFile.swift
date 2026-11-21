import Foundation

/// A Files pick handed to the app by URL. Adoption never reads the original into memory.
public struct PushPickedFile: Sendable {
    public let name: String
    public let url: URL

    public init(_ source: URL, outbox: PushOutbox) throws {
        let base = source.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let clean = base.isEmpty || base.hasPrefix(".") ? "file" + base : base
        name = String(UUID().uuidString.prefix(8)).lowercased() + "-" + String(clean.suffix(120))
        try outbox.adopt(source, as: name, move: true)
        url = outbox.attachments.appendingPathComponent(name)
    }

    /// The extension may skip expensive preview decoding; the original is still staged and sent.
    public static func previewURL(_ url: URL) -> URL? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= 25 * 1024 * 1024 else { return nil }
        return url
    }
}
