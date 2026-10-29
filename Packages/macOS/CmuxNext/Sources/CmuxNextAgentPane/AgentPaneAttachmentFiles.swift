import Foundation
import CmuxNextCompat

/// A composer chip's contents (a pasted screenshot, a PDF, a recording) as a file of its own in a
/// folder, so the JSON that lists the chips stays small (``AgentPaneRelaunchWake``,
/// ``AgentPaneDraftAttachments``). A chip keeps its name and kind without `data`; a map names each
/// chip's file by attachment id.
nonisolated enum AgentPaneAttachmentFiles {
    typealias Attachment = AgentPaneWakeState.Attachment

    /// `attachments` with each one's contents written to its own file in `folder`, the files by
    /// attachment id, and how many bytes they hold; nil when they hold more than `budget` or a file
    /// can't be written (the files this call wrote are gone then). A chip sent without its contents
    /// keeps the file `kept` names for it; one that carries bytes and has neither is left out.
    static func moveOut(_ attachments: [Attachment], to folder: URL, within budget: Int,
                        kept: [String: String] = [:]) -> (attachments: [Attachment], files: [String: String], bytes: Int)? {
        // Attachment ids are the persistence key. A reconnect or a rapid paste/remove race can
        // hand us the same id twice; keeping both entries would make them read back the last
        // file twice and leave the first file orphaned. The latest entry is the authoritative one,
        // matching the composer's current list semantics.
        var seen = Set<String>()
        let unique = attachments.reversed().filter { seen.insert($0.id).inserted }.reversed()
        var files: [String: String] = [:]
        var bytes = 0
        var written: [URL] = []
        var moved: [Attachment] = []
        for var attachment in unique {
            if let data = attachment.data, let contents = Data(base64Encoded: data) {
                bytes += contents.count
                let url = folder.appending(path: "\(UUID().uuidString).\(fileExtension(attachment.mimeType))")
                do {
                    guard bytes <= budget else { throw CocoaError(.fileWriteOutOfSpace) }
                    try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
                    try contents.write(to: url, options: .atomic)
                } catch {
                    for url in written { try? FileManager.checked.removeItem(at: url) }
                    return nil
                }
                written.append(url)
                files[attachment.id] = url.lastPathComponent
                attachment.data = nil
            } else if attachment.data == nil, let name = kept[attachment.id], let size = size(of: name, in: folder) {
                bytes += size
                guard bytes <= budget else {
                    for url in written { try? FileManager.checked.removeItem(at: url) }
                    return nil
                }
                files[attachment.id] = name
            } else if attachment.data == nil, carriesBytes(attachment) {
                continue
            }
            moved.append(attachment)
        }
        return (moved, files, bytes)
    }

    /// `attachments` with each one's contents read back from the file `files` names for it in
    /// `folder`, within `budget` bytes (what is read is taken off it). A chip whose file is missing,
    /// past the budget or not a bare name in the folder is left out.
    static func readBack(_ attachments: [Attachment], files: [String: String], in folder: URL, budget: inout Int) -> [Attachment] {
        attachments.compactMap { attachment in
            guard let name = files[attachment.id] else { return attachment }
            guard let size = size(of: name, in: folder), size <= budget,
                  // concurrency-allow: the capped attachment files a composer kept, read once when its chat opens
                  let bytes = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            budget -= size
            var attachment = attachment
            attachment.data = bytes.base64EncodedString()
            return attachment
        }
    }

    /// The size of file `name` in `folder`; nil when there is none, or `name` is not a bare name
    /// this code gives (never a path out of the folder).
    static func size(of name: String, in folder: URL) -> Int? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return (try? folder.appending(path: name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// A chip that is nothing without its contents: an image, a PDF, a recording.
    static func carriesBytes(_ attachment: Attachment) -> Bool {
        ["image", "document", "audio"].contains(attachment.kind)
    }

    /// The file's extension for a chip's MIME type, so the copy opens as what it is.
    static func fileExtension(_ mimeType: String) -> String {
        switch mimeType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "application/pdf": "pdf"
        default: "bin"
        }
    }
}
