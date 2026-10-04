public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The owner's attachment rules (home-messaging.md 10.1), checked on the
/// client before any upload so a refused file never leaves the device.
public enum HomeAttachmentPolicy {
    /// Per file, every type (decimal megabytes, like the owner).
    public static let maxBytes = 100_000_000
    /// Up to this size a source streams the bytes through the owner's
    /// Worker; larger files go to a presigned PUT followed by a commit call.
    public static let streamMaxBytes = 32_000_000
    /// At most this many parts per message (attachments plus text).
    public static let maxParts = 16
    /// A video's poster: at most this size, one of `posterTypes`.
    public static let posterMaxBytes = 2_000_000
    public static let posterTypes: Set<String> = ["image/jpeg", "image/webp"]

    /// The allow list: mime type -> inbox preview kind. SVG, HTML and XML are never on it.
    public static let allowedTypes: [String: AttachmentPreview.Kind] = [
        "image/jpeg": .photo, "image/png": .photo, "image/gif": .photo, "image/webp": .photo, "image/heic": .photo,
        "application/pdf": .file, "text/plain": .file, "text/markdown": .file, "text/csv": .file,
        "application/json": .file, "application/zip": .file,
        "video/mp4": .video, "video/quicktime": .video,
        "audio/mp4": .audio, "audio/mpeg": .audio, "audio/aac": .audio, "audio/wav": .audio,
    ]

    /// File extensions of the allowed types, so the mime type does not
    /// depend on the OS's UTType tables.
    static let extensionTypes: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "pdf": "application/pdf", "txt": "text/plain", "text": "text/plain",
        "md": "text/markdown", "markdown": "text/markdown", "csv": "text/csv", "json": "application/json",
        "zip": "application/zip", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "qt": "video/quicktime",
        "m4a": "audio/mp4", "mp3": "audio/mpeg", "aac": "audio/aac", "wav": "audio/wav",
    ]

    /// Other spellings the OS uses for allowed types.
    static let aliases: [String: String] = [
        "image/jpg": "image/jpeg", "audio/x-m4a": "audio/mp4", "audio/m4a": "audio/mp4", "audio/mp3": "audio/mpeg",
        "audio/x-aac": "audio/aac", "audio/vnd.wave": "audio/wav", "audio/wave": "audio/wav", "audio/x-wav": "audio/wav",
        "text/x-markdown": "text/markdown", "application/x-zip-compressed": "application/zip",
    ]

    /// A file name: at most this many characters (Unicode scalars, as the
    /// owner counts them).
    public static let maxNameCharacters = 255
    /// Valid `width` and `height` of a part; other values are left out.
    public static let dimensionRange = 1...100_000
    /// Valid `duration_ms` of a part (24 hours); other values are left out.
    public static let durationRange = 0...86_400_000

    /// Extensions the owner refuses whatever the declared type (executables,
    /// installers, scripts, active documents).
    static let deniedExtensions: Set<String> = [
        "exe", "dll", "msi", "msp", "msix", "appx", "bat", "cmd", "com", "scr", "pif", "cpl", "msc", "hta", "gadget", "lnk",
        "reg", "inf", "ps1", "psm1", "vbs", "vbe", "js", "jse", "mjs", "cjs", "wsf", "wsh", "jar", "class",
        "app", "dmg", "pkg", "mpkg", "command", "workflow", "action", "scpt", "applescript", "terminal", "tool", "kext", "dylib",
        "so", "sh", "bash", "zsh", "csh", "fish", "ksh", "run", "bin", "elf", "apk", "aab", "ipa", "deb", "rpm", "appimage",
        "snap", "flatpak", "html", "htm", "xhtml", "shtml", "svg", "svgz", "xml", "xsl", "mht", "mhtml", "webloc", "url",
        "desktop", "iso", "img", "vhd", "vhdx",
    ]

    /// Characters a name may not hold: control characters, the line and
    /// paragraph separators, and path separators.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
            || scalar == "/" || scalar == "\\"
    }

    /// The owner's name rule: 1 to 255 characters, none forbidden, not
    /// blank, `.` or `..`.
    public static func isValidName(_ name: String) -> Bool {
        let count = name.unicodeScalars.count
        return count > 0 && count <= maxNameCharacters && !name.unicodeScalars.contains(where: isForbidden)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".."
    }

    /// True when the owner refuses the name's extension.
    public static func isDeniedName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return deniedExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// A file's own name made valid: forbidden characters become `_`, a
    /// name over 255 characters is cut before its extension, and a blank
    /// name becomes `attachment`.
    public static func sendableName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars { scalars.append(isForbidden(scalar) ? "_" : scalar) }
        var cleaned = String(scalars)
        if cleaned.unicodeScalars.count > maxNameCharacters {
            let ext = (cleaned as NSString).pathExtension
            let suffix = ext.isEmpty || ext.unicodeScalars.count >= maxNameCharacters - 1 ? "" : "." + ext
            let base = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
            let keep = maxNameCharacters - suffix.unicodeScalars.count
            cleaned = String(String.UnicodeScalarView(base.unicodeScalars.prefix(keep))) + suffix
        }
        return isValidName(cleaned) ? cleaned : "attachment"
    }

    /// The ref as the owner accepts it: the canonical mime type, and no
    /// width, height or duration outside the owner's ranges.
    public static func normalized(_ ref: AttachmentRef) -> AttachmentRef {
        var ref = ref
        ref.mimeType = canonicalMimeType(ref.mimeType)
        if let width = ref.width, !dimensionRange.contains(width) { ref.width = nil }
        if let height = ref.height, !dimensionRange.contains(height) { ref.height = nil }
        if let duration = ref.durationMs, !durationRange.contains(duration) { ref.durationMs = nil }
        return ref
    }

    // MARK: Accepted input

    /// What `prepare` does with input of one type.
    enum InputDecision: Hashable, Sendable {
        /// Sent as is, with this owner mime type.
        case send(mimeType: String)
        /// An image the owner refuses but ImageIO reads: converted to PNG or JPEG.
        case convert
        case refuse
    }

    /// The decision for in-memory input of `type`
    /// (`prepareAttachment(data:typeIdentifier:)`): the type's own mime
    /// type when the owner allows it (an M4A type may prefer the .mp4
    /// extension), else its extension's; an image type ImageIO reads (by
    /// conformance) is converted; a denied extension is refused.
    static func decision(for type: UTType) -> InputDecision {
        let fileExtension = type.preferredFilenameExtension ?? ""
        if !fileExtension.isEmpty, isDeniedName("attachment.\(fileExtension)") { return .refuse }
        let typeMime = canonicalMimeType(type.preferredMIMEType ?? "application/octet-stream")
        let mime = allowedTypes[typeMime] != nil || fileExtension.isEmpty
            ? typeMime
            : AttachmentMedia.mimeType(forExtension: fileExtension)
        if allowedTypes[mime] != nil { return .send(mimeType: mime) }
        if type.conforms(to: .image), convertibleImageTypes.contains(where: { type.conforms(to: $0) }) { return .convert }
        return .refuse
    }

    /// The decision for a file (`prepareAttachment(fileURL:)`): the
    /// extension's owner mime type, else the decision for its UTType.
    static func decision(forFileExtension fileExtension: String) -> InputDecision {
        let ext = fileExtension.lowercased()
        if isDeniedName("attachment.\(ext)") { return .refuse }
        if let known = extensionTypes[ext] { return .send(mimeType: known) }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .refuse }
        return decision(for: type)
    }

    /// Image types ImageIO reads that the owner refuses (TIFF, HEIF, BMP,
    /// camera RAW): prepare converts them.
    static let convertibleImageTypes: [UTType] = {
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return readable.compactMap(UTType.init).filter { type in
            guard type.conforms(to: .image) else { return false }
            let mime = canonicalMimeType(type.preferredMIMEType ?? "")
            let ext = type.preferredFilenameExtension ?? ""
            return allowedTypes[mime] == nil && (ext.isEmpty || !isDeniedName("attachment.\(ext)"))
        }
    }()

    /// UTType identifiers `prepareAttachment` takes after conversion: the
    /// allow list's types and the image types it converts. A composer
    /// checks drops and pastes with `accepts(typeIdentifier:)`, which also
    /// takes types that conform to a converted image type.
    public static let acceptedInputTypes: Set<String> = {
        var identifiers = Set(convertibleImageTypes.map(\.identifier))
        for ext in extensionTypes.keys {
            guard let type = UTType(filenameExtension: ext), decision(for: type) != .refuse else { continue }
            identifiers.insert(type.identifier)
        }
        return identifiers
    }()

    /// True exactly when `prepareAttachment(data:typeIdentifier:)` takes
    /// input of this type (it may still refuse bytes that are not what the
    /// type says, or a file over the size limit).
    public static func accepts(typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return decision(for: type) != .refuse
    }

    /// True exactly when `prepareAttachment(fileURL:)` takes a file with
    /// this URL's extension (same caveats).
    public static func accepts(fileURL: URL) -> Bool {
        decision(forFileExtension: fileURL.pathExtension) != .refuse
    }

    /// The owner's spelling of a mime type (lowercased, aliases folded).
    public static func canonicalMimeType(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        return aliases[lower] ?? lower
    }

    /// Throws `HomeAttachmentError` when the owner would refuse the file.
    public static func check(mimeType: String, byteCount: Int, name: String) throws {
        guard isValidName(name) else { throw HomeAttachmentError.invalidName(name: name) }
        guard allowedTypes[canonicalMimeType(mimeType)] != nil, !isDeniedName(name) else {
            throw HomeAttachmentError.typeRefused(mimeType: mimeType, name: name)
        }
        guard byteCount <= maxBytes else { throw HomeAttachmentError.tooLarge(byteCount: byteCount, limit: maxBytes) }
        guard byteCount > 0 else { throw HomeAttachmentError.empty(name: name) }
    }
}

/// Why the client refused an attachment before uploading it.
public enum HomeAttachmentError: Error, Hashable, Sendable {
    /// Not on the allow list (images, PDF, plain text, Markdown, CSV, JSON,
    /// ZIP, MP4, MOV, M4A, MP3, AAC, WAV), or an extension the owner refuses
    /// (scripts, executables, HTML, SVG).
    case typeRefused(mimeType: String, name: String)
    /// Over 255 characters, blank, `.` or `..`, or holding a control
    /// character or a path separator.
    case invalidName(name: String)
    /// Over `HomeAttachmentPolicy.maxBytes`.
    case tooLarge(byteCount: Int, limit: Int)
    /// A file with no bytes.
    case empty(name: String)
    /// More than `HomeAttachmentPolicy.maxParts` parts in one message.
    case tooManyParts(limit: Int)
}

/// The inbox preview of a message's attachments ("2 photos"); clients
/// localize the label. The owner's `preview_attachments {kind, count}`.
public struct AttachmentPreview: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case photo, video, audio, file
    }

    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }

    /// The owner's rule: one kind when every attachment has it, else `.file`;
    /// nil without attachments.
    public static func of(_ parts: [MessagePart]) -> AttachmentPreview? {
        let kinds = parts.compactMap { part -> Kind? in
            guard case .attachment(let ref) = part else { return nil }
            return HomeAttachmentPolicy.allowedTypes[HomeAttachmentPolicy.canonicalMimeType(ref.mimeType)] ?? .file
        }
        guard let first = kinds.first else { return nil }
        return AttachmentPreview(kind: kinds.allSatisfy { $0 == first } ? first : .file, count: kinds.count)
    }
}

/// Where an attachment appears: what the owner needs to mint a download
/// URL (the conversation, and the message part that references the hash).
public struct AttachmentLocation: Hashable, Sendable {
    public var conversation: ConversationID
    public var message: MessageID?
    public var partIndex: Int?

    public init(conversation: ConversationID, message: MessageID? = nil, partIndex: Int? = nil) {
        self.conversation = conversation
        self.message = message
        self.partIndex = partIndex
    }
}
