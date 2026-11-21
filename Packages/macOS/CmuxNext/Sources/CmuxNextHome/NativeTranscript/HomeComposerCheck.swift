import CmuxHomeCore
import Foundation
import UniformTypeIdentifiers

/// The composer's check before preparing, with the data side's own rule
/// (`HomeAttachmentPolicy.accepts`, which knows what it converts) for the
/// type, so paste, drop, the drag check and the picker agree and a refused
/// file is never hashed or copied. Original file size is unbounded.
nonisolated enum HomeComposerCheck {
    /// The types the file picker offers: none named, so every file (any file
    /// attaches; the data side sends unlisted ones as text or a generic file).
    static var pickerTypes: [UTType] { [] }

    /// Whether the data side takes a file of this URL's type.
    static func accepts(_ url: URL) -> Bool { HomeAttachmentPolicy.accepts(fileURL: url) }

    /// Nil when the input may be attached, else why not and the name the notice uses (nil: the
    /// pasted item). A file costs a stat (folder, size), so the composer runs this off the main
    /// actor (`HomeNativeTranscriptView.attach`).
    static func problem(for input: HomeDraftInput) -> (error: HomeAttachmentError, name: String?)? {
        let name: String?, accepted: Bool, size: Int, typeName: String
        switch input {
        case .file(let url):
            // A stat for the size only; the bytes are read by the data side.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            name = url.lastPathComponent
            guard accepts(url) else { return (.folder(name: url.lastPathComponent), name) }
            accepted = true
            size = values?.fileSize ?? 0
            typeName = url.pathExtension
        case .data(let data, let identifier):
            name = nil
            accepted = HomeAttachmentPolicy.accepts(typeIdentifier: identifier)
            size = data.count
            typeName = identifier
        }
        guard accepted else { return (.typeRefused(mimeType: typeName, name: name ?? ""), name) }
        if size == 0 { return (.empty(name: name ?? ""), name) }
        return nil
    }

    /// The notice for a problem `problem(for:)` found.
    @MainActor
    static func notice(_ problem: (error: HomeAttachmentError, name: String?)) -> String {
        HomeStrings.attachmentRefusal(problem.error, name: problem.name ?? HomeStrings.pastedItem)
    }
}
