#if !canImport(UniformTypeIdentifiers)
/// The part of `UniformTypeIdentifiers.UTType` the attachment code uses, for
/// platforms without that framework (Linux): a fixed table of the types the
/// owner accepts plus the ones prepare names, with the identifiers, MIME
/// types and extensions Apple's table gives them. As on Apple platforms, any
/// MIME type of a type finds it, not only the preferred one. An identifier,
/// extension or MIME type outside the table has no type (Apple would make a
/// dynamic one), which prepare treats the same way: the bytes are sniffed.
struct UTType: Hashable, Sendable {
    let identifier: String
    /// Every MIME type of the type, the preferred one first.
    let mimeTypes: [String]
    /// Every extension of the type, the preferred one first.
    let filenameExtensions: [String]
    let supertypeIdentifiers: [String]

    var preferredMIMEType: String? { mimeTypes.first }
    var preferredFilenameExtension: String? { filenameExtensions.first }

    init?(_ identifier: String) {
        guard let type = Self.table.first(where: { $0.identifier == identifier }) else { return nil }
        self = type
    }

    init?(filenameExtension: String) {
        let ext = filenameExtension.lowercased()
        guard let type = Self.table.first(where: { $0.filenameExtensions.contains(ext) }) else { return nil }
        self = type
    }

    init?(mimeType: String) {
        let mime = mimeType.lowercased()
        guard let type = Self.table.first(where: { $0.mimeTypes.contains(mime) }) else { return nil }
        self = type
    }

    private init(_ identifier: String, mime: [String], extensions: [String], conformsTo supertypes: [String]) {
        self.identifier = identifier
        mimeTypes = mime
        filenameExtensions = extensions
        supertypeIdentifiers = supertypes
    }

    func conforms(to type: UTType) -> Bool {
        identifier == type.identifier
            || supertypeIdentifiers.contains { UTType($0)?.conforms(to: type) ?? false }
    }

    static let data = UTType("public.data", mime: [], extensions: [], conformsTo: [])
    static let text = UTType("public.text", mime: [], extensions: [], conformsTo: ["public.data"])
    static let image = UTType("public.image", mime: [], extensions: [], conformsTo: ["public.data"])
    static let plainText = UTType("public.plain-text", mime: ["text/plain"], extensions: ["txt", "text"],
                                  conformsTo: ["public.text"])
    static let html = UTType("public.html", mime: ["text/html"], extensions: ["html", "htm"],
                             conformsTo: ["public.text"])
    static let commaSeparatedText = UTType("public.comma-separated-values-text", mime: ["text/csv"],
                                           extensions: ["csv"], conformsTo: ["public.text"])
    static let json = UTType("public.json", mime: ["application/json"], extensions: ["json"],
                             conformsTo: ["public.text"])
    static let jpeg = UTType("public.jpeg", mime: ["image/jpeg", "image/jpg"], extensions: ["jpeg", "jpg"],
                             conformsTo: ["public.image"])
    static let png = UTType("public.png", mime: ["image/png"], extensions: ["png"], conformsTo: ["public.image"])
    static let gif = UTType("com.compuserve.gif", mime: ["image/gif"], extensions: ["gif"],
                            conformsTo: ["public.image"])
    static let webP = UTType("org.webmproject.webp", mime: ["image/webp"], extensions: ["webp"],
                             conformsTo: ["public.image"])
    static let heic = UTType("public.heic", mime: ["image/heic"], extensions: ["heic"], conformsTo: ["public.image"])
    static let tiff = UTType("public.tiff", mime: ["image/tiff"], extensions: ["tiff", "tif"],
                             conformsTo: ["public.image"])
    static let svg = UTType("public.svg-image", mime: ["image/svg+xml"], extensions: ["svg"],
                            conformsTo: ["public.image"])
    static let pdf = UTType("com.adobe.pdf", mime: ["application/pdf"], extensions: ["pdf"],
                            conformsTo: ["public.data"])
    static let zip = UTType("public.zip-archive", mime: ["application/zip", "application/x-zip-compressed"],
                            extensions: ["zip"], conformsTo: ["public.data"])
    static let mpeg4Movie = UTType("public.mpeg-4", mime: ["video/mp4"], extensions: ["mp4"],
                                   conformsTo: ["public.data"])
    static let quickTimeMovie = UTType("com.apple.quicktime-movie", mime: ["video/quicktime"], extensions: ["mov", "qt"],
                                       conformsTo: ["public.data"])
    static let mpeg4Audio = UTType("public.mpeg-4-audio", mime: ["audio/mp4", "audio/x-m4a", "audio/m4a"],
                                   extensions: ["m4a"], conformsTo: ["public.data"])
    static let mp3 = UTType("public.mp3", mime: ["audio/mpeg", "audio/mp3"], extensions: ["mp3"],
                            conformsTo: ["public.data"])
    static let wav = UTType("com.microsoft.waveform-audio",
                            mime: ["audio/vnd.wave", "audio/wav", "audio/wave", "audio/x-wav"], extensions: ["wav"],
                            conformsTo: ["public.data"])
    private static let markdown = UTType("net.daringfireball.markdown", mime: ["text/markdown", "text/x-markdown"],
                                         extensions: ["md", "markdown"], conformsTo: ["public.plain-text"])
    private static let aac = UTType("public.aac-audio", mime: ["audio/aac", "audio/x-aac"], extensions: ["aac"],
                                    conformsTo: ["public.data"])
    private static let m4v = UTType("com.apple.m4v-video", mime: ["video/x-m4v"], extensions: ["m4v"],
                                    conformsTo: ["public.data"])

    private static let table: [UTType] = [
        data, text, image, plainText, html, commaSeparatedText, json, jpeg, png, gif, webP, heic, tiff, svg, pdf, zip,
        mpeg4Movie, quickTimeMovie, mpeg4Audio, mp3, wav, markdown, aac, m4v,
    ]
}
#endif
