import Foundation
import UniformTypeIdentifiers

/// A file attachment's details, as Messages shows them in its document
/// bubble: the name, the type (a uniform type identifier) and the size.
public struct ConversationFileInfo: Sendable, Hashable {
    /// The file name with its extension, e.g. "Quarterly Report.pdf".
    public var name: String
    /// Uniform type identifier, e.g. "com.adobe.pdf".
    public var uti: String
    public var byteCount: Int64

    public init(name: String, uti: String, byteCount: Int64) {
        self.name = name
        self.uti = uti
        self.byteCount = byteCount
    }

    /// Infers the type from the name's extension, then from `mimeType`;
    /// unknown files are `public.data`.
    public init(name: String, mimeType: String?, byteCount: Int64) {
        self.init(name: name, uti: Self.uti(name: name, mimeType: mimeType), byteCount: byteCount)
    }

    public var type: UTType { UTType(uti) ?? .data }

    /// Images sent as files still open in the photo viewer.
    public var isImage: Bool { type.conforms(to: .image) }

    /// The MIME type the upload declares.
    public var mimeType: String { type.preferredMIMEType ?? "application/octet-stream" }

    /// "PDF Document", "ZIP archive", "Plain Text"... (the system's localized
    /// type description; Messages' document bubble subtitle).
    public var typeDescription: String {
        type.localizedDescription ?? URL(fileURLWithPath: name).pathExtension.uppercased()
    }

    /// "1.2 MB", as Messages and Files format sizes.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func uti(name: String, mimeType: String?) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic { return type.identifier }
        if let mimeType, let type = UTType(mimeType: mimeType), !type.isDynamic { return type.identifier }
        return UTType.data.identifier
    }
}

/// A file picked for sending, waiting for upload.
public struct ConversationPendingFile: Sendable, Hashable {
    public var data: Data
    public var info: ConversationFileInfo

    public init(data: Data, info: ConversationFileInfo) {
        self.data = data
        self.info = info
    }

    /// `name`'s type; a picked image becomes a photo attachment instead.
    public init(data: Data, name: String) {
        self.init(data: data, info: ConversationFileInfo(name: name, mimeType: nil, byteCount: Int64(data.count)))
    }
}

extension ConversationMessage {
    /// The message's documents (anything that is not a photo or recording).
    public var fileAttachments: [ConversationAttachment] {
        attachments.filter { $0.kind == .file }
    }
}

/// Backends that carry arbitrary files adopt this beside `ConversationBackend`.
public protocol ConversationFileBackend: ConversationBackend {
    func uploadFileAttachment(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment
}

extension ConversationBackend {
    /// Uploads a document. Backends without file support refuse it, so the
    /// send fails visibly instead of dropping the file.
    public func uploadFile(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment {
        if let files = self as? any ConversationFileBackend {
            return try await files.uploadFileAttachment(data, info: info)
        }
        throw ConversationBackendError(code: -1, message: "file attachments are not supported")
    }
}
