import CmuxHomeCore
import CmuxNextHomeModel
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
        let checked: Input
        switch input {
        case .file(let url):
            // A stat for the size only; the bytes are read by the data side.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            checked = Input(kind: "file", name: url.lastPathComponent, identifier: nil, accepted: accepts(url), size: size)
        case .data(let data, let identifier):
            checked = Input(kind: "data", name: nil, identifier: identifier,
                            accepted: HomeAttachmentPolicy.accepts(typeIdentifier: identifier), size: data.count)
        }
        let found: Problem? = HomeComposeRules().call("composerCheck.problem", Request(input: checked), fallback: nil)
        guard let found else { return nil }
        let error: HomeAttachmentError = switch found.kind {
        case "folder": .folder(name: found.name)
        case "typeRefused": .typeRefused(mimeType: found.mimeType ?? "", name: found.name)
        default: .empty(name: found.name)
        }
        return (error, found.shown)
    }

    /// `compose.composerCheck.problem`'s input: a file (its name) or pasted data (its type).
    private struct Input: Encodable {
        var kind: String
        var name: String?
        var identifier: String?
        var accepted: Bool
        var size: Int
    }

    private struct Request: Encodable {
        var input: Input
    }

    /// Why the input is refused (`folder`, `typeRefused`, `empty`) and the name the notice shows.
    private struct Problem: Decodable {
        var kind: String
        var name: String
        var shown: String?
        var mimeType: String?
    }

    /// The notice for a problem `problem(for:)` found.
    @MainActor
    static func notice(_ problem: (error: HomeAttachmentError, name: String?)) -> String {
        HomeStrings.attachmentRefusal(problem.error, name: problem.name ?? HomeStrings.pastedItem)
    }
}
