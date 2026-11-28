#if !canImport(UniformTypeIdentifiers)
import Foundation

/// The common file types, for builds without UniformTypeIdentifiers (the
/// Linux CI package build). Apple builds ask UTType and never compile this.
enum ConversationFileTypeTable {
    private struct Entry {
        var uti: String
        var extensions: [String]
        var mimeTypes: [String]
        var description: String
        var isImage = false
    }

    private static let entries: [Entry] = [
        Entry(uti: "com.adobe.pdf", extensions: ["pdf"], mimeTypes: ["application/pdf"], description: "PDF document"),
        Entry(uti: "public.zip-archive", extensions: ["zip"], mimeTypes: ["application/zip"], description: "ZIP archive"),
        Entry(uti: "public.plain-text", extensions: ["txt", "text"], mimeTypes: ["text/plain"], description: "Plain text"),
        Entry(uti: "public.json", extensions: ["json"], mimeTypes: ["application/json"], description: "JSON"),
        Entry(uti: "public.html", extensions: ["html", "htm"], mimeTypes: ["text/html"], description: "HTML text"),
        Entry(uti: "public.comma-separated-values-text", extensions: ["csv"], mimeTypes: ["text/csv"], description: "CSV text"),
        Entry(uti: "public.png", extensions: ["png"], mimeTypes: ["image/png"], description: "PNG image", isImage: true),
        Entry(uti: "public.jpeg", extensions: ["jpg", "jpeg"], mimeTypes: ["image/jpeg"], description: "JPEG image", isImage: true),
        Entry(uti: "com.compuserve.gif", extensions: ["gif"], mimeTypes: ["image/gif"], description: "GIF image", isImage: true),
        Entry(uti: "public.heic", extensions: ["heic"], mimeTypes: ["image/heic"], description: "HEIC image", isImage: true),
        Entry(uti: "org.webmproject.webp", extensions: ["webp"], mimeTypes: ["image/webp"], description: "WebP image", isImage: true),
        Entry(uti: "com.microsoft.waveform-audio", extensions: ["wav"], mimeTypes: ["audio/wav", "audio/x-wav"], description: "Waveform audio"),
        Entry(uti: "public.mpeg-4", extensions: ["mp4"], mimeTypes: ["video/mp4"], description: "MPEG-4 movie"),
    ]

    static func uti(filenameExtension ext: String) -> String? {
        let ext = ext.lowercased()
        return entries.first { $0.extensions.contains(ext) }?.uti
    }

    static func uti(mimeType: String) -> String? {
        let mimeType = mimeType.lowercased()
        return entries.first { $0.mimeTypes.contains(mimeType) }?.uti
    }

    static func mimeType(uti: String) -> String? { entries.first { $0.uti == uti }?.mimeTypes.first }

    static func description(uti: String) -> String? {
        guard let description = entries.first(where: { $0.uti == uti })?.description else { return nil }
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    static func isImage(uti: String) -> Bool { entries.first { $0.uti == uti }?.isImage ?? false }
}
#endif
