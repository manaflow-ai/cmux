#if !canImport(UniformTypeIdentifiers)
import Foundation

/// The `UTType` surface this package and its tests use, for platforms without
/// UniformTypeIdentifiers (the Linux package lane). A fixed table of the types
/// attachments meet, with Apple's identifiers, preferred extensions, preferred
/// mime types and conformance; any other identifier, extension or mime type is
/// unknown (nil), as an undeclared one is on Apple platforms.
struct UTType: Hashable, Sendable {
    let identifier: String
    let preferredFilenameExtension: String?
    let preferredMIMEType: String?
    private let extensions: [String]
    private let mimeTypes: [String]
    private let parents: [String]

    private init(_ identifier: String, extensions: [String] = [], mimeTypes: [String] = [], parents: [String]) {
        self.identifier = identifier
        self.preferredFilenameExtension = extensions.first
        self.preferredMIMEType = mimeTypes.first
        self.extensions = extensions
        self.mimeTypes = mimeTypes
        self.parents = parents
    }

    init?(_ identifier: String) {
        guard let known = Self.table.first(where: { $0.identifier == identifier }) else { return nil }
        self = known
    }

    init?(filenameExtension: String) {
        let ext = filenameExtension.lowercased()
        guard let known = Self.table.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = known
    }

    init?(mimeType: String) {
        let mime = mimeType.lowercased()
        guard let known = Self.table.first(where: { $0.mimeTypes.contains(mime) }) else { return nil }
        self = known
    }

    func conforms(to other: UTType) -> Bool {
        if other.identifier == identifier { return true }
        return parents.contains { parent in
            parent == other.identifier || (UTType(parent)?.conforms(to: other) ?? false)
        }
    }

    static func == (lhs: UTType, rhs: UTType) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    static let item = UTType("public.item", parents: [])
    static let data = UTType("public.data", parents: ["public.item"])
    static let content = UTType("public.content", parents: [])
    static let text = UTType("public.text", parents: ["public.data", "public.content"])
    static let plainText = UTType("public.plain-text", extensions: ["txt", "text"], mimeTypes: ["text/plain"],
                                  parents: ["public.text"])
    static let html = UTType("public.html", extensions: ["html", "htm"], mimeTypes: ["text/html"], parents: ["public.text"])
    static let json = UTType("public.json", extensions: ["json"], mimeTypes: ["application/json"], parents: ["public.text"])
    static let commaSeparatedText = UTType("public.comma-separated-values-text", extensions: ["csv"],
                                           mimeTypes: ["text/csv", "text/comma-separated-values"], parents: ["public.text"])
    static let markdown = UTType("net.daringfireball.markdown", extensions: ["md", "markdown"], mimeTypes: ["text/markdown"],
                                 parents: ["public.plain-text"])
    static let pdf = UTType("com.adobe.pdf", extensions: ["pdf"], mimeTypes: ["application/pdf"],
                            parents: ["public.data", "public.content"])
    static let zip = UTType("public.zip-archive", extensions: ["zip"], mimeTypes: ["application/zip"], parents: ["public.data"])
    static let image = UTType("public.image", parents: ["public.data", "public.content"])
    static let png = UTType("public.png", extensions: ["png"], mimeTypes: ["image/png"], parents: ["public.image"])
    static let jpeg = UTType("public.jpeg", extensions: ["jpeg", "jpg", "jpe"], mimeTypes: ["image/jpeg", "image/jpg"],
                             parents: ["public.image"])
    static let gif = UTType("com.compuserve.gif", extensions: ["gif"], mimeTypes: ["image/gif"], parents: ["public.image"])
    static let webP = UTType("org.webmproject.webp", extensions: ["webp"], mimeTypes: ["image/webp"], parents: ["public.image"])
    static let tiff = UTType("public.tiff", extensions: ["tiff", "tif"], mimeTypes: ["image/tiff"], parents: ["public.image"])
    static let bmp = UTType("com.microsoft.bmp", extensions: ["bmp"], mimeTypes: ["image/bmp"], parents: ["public.image"])
    static let heif = UTType("public.heif", extensions: ["heif"], mimeTypes: ["image/heif"], parents: ["public.image"])
    static let heic = UTType("public.heic", extensions: ["heic"], mimeTypes: ["image/heic"], parents: ["public.heif"])
    static let svg = UTType("public.svg-image", extensions: ["svg"], mimeTypes: ["image/svg+xml"],
                            parents: ["public.image", "public.text"])
    static let audiovisualContent = UTType("public.audiovisual-content", parents: ["public.data", "public.content"])
    static let movie = UTType("public.movie", parents: ["public.audiovisual-content"])
    static let audio = UTType("public.audio", parents: ["public.audiovisual-content"])
    static let mpeg4Movie = UTType("public.mpeg-4", extensions: ["mp4", "mpeg4"], mimeTypes: ["video/mp4"], parents: ["public.movie"])
    static let quickTimeMovie = UTType("com.apple.quicktime-movie", extensions: ["mov", "qt"], mimeTypes: ["video/quicktime"],
                                       parents: ["public.movie"])
    static let mpeg4Audio = UTType("public.mpeg-4-audio", extensions: ["m4a"], mimeTypes: ["audio/mp4", "audio/x-m4a"],
                                   parents: ["public.audio"])
    static let mp3 = UTType("public.mp3", extensions: ["mp3"], mimeTypes: ["audio/mpeg", "audio/mp3"], parents: ["public.audio"])
    static let aac = UTType("public.aac-audio", extensions: ["aac"], mimeTypes: ["audio/aac", "audio/x-aac"], parents: ["public.audio"])
    static let wav = UTType("com.microsoft.waveform-audio", extensions: ["wav", "wave"],
                            mimeTypes: ["audio/vnd.wave", "audio/wav", "audio/wave", "audio/x-wav"], parents: ["public.audio"])

    private static let table: [UTType] = [
        item, data, content, text, plainText, html, json, commaSeparatedText, markdown, pdf, zip,
        image, png, jpeg, gif, webP, tiff, bmp, heif, heic, svg,
        audiovisualContent, movie, audio, mpeg4Movie, quickTimeMovie, mpeg4Audio, mp3, aac, wav,
    ]
}
#endif
