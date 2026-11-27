import Foundation

/// A composer chip's contents (a pasted screenshot, a PDF, a recording) as a file of its own in a
/// folder, so the JSON that lists the chips stays small (``AgentPaneRelaunchWake``,
/// ``AgentPaneDraftAttachments``). A chip keeps its name and kind without `data`; a map names each
/// chip's file by attachment id.
nonisolated enum AgentPaneAttachmentFiles {
    typealias Attachment = AgentPaneWakeState.Attachment

    /// Which of a chip's fields a file holds: its base64 bytes (`data`) or its text (`text`).
    nonisolated enum Contents: Equatable {
        /// An image's, a PDF's or a recording's bytes, base64 in the chip.
        case bytes
        /// A text file's contents or a pasted chip's text.
        case text

        var field: WritableKeyPath<Attachment, String?> {
            switch self {
            case .bytes: \.data
            case .text: \.text
            }
        }

        /// The file's contents for a chip's field; nil when the field holds no valid contents.
        func file(_ value: String) -> Data? {
            switch self {
            case .bytes: Data(base64Encoded: value)
            case .text: Data(value.utf8)
            }
        }

        /// The chip's field for a file's contents.
        func value(_ file: Data) -> String {
            switch self {
            case .bytes: file.base64EncodedString()
            case .text: String(decoding: file, as: UTF8.self)
            }
        }
    }

    /// `attachments` with each one's `contents` written to its own file in `folder`, and the files
    /// by attachment id; nil when a file can't be written (the files this call wrote are gone
    /// then). There is no size budget: a chip of any size keeps its contents (Leo 2026-10-26). A
    /// chip sent without its bytes keeps the file `kept` names for it; one that carries bytes and
    /// has neither is left out.
    static func moveOut(_ attachments: [Attachment], _ contents: Contents = .bytes, to folder: URL,
                        kept: [String: String] = [:]) -> (attachments: [Attachment], files: [String: String])? {
        let manager = FileManager.default
        // Attachment ids are the persistence key. A reconnect or a rapid paste/remove race can
        // hand us the same id twice; keeping both entries would make them read back the last
        // file twice and leave the first file orphaned. The latest entry is the authoritative one,
        // matching the composer's current list semantics.
        var seen = Set<String>()
        let unique = attachments.reversed().filter { seen.insert($0.id).inserted }.reversed()
        var files: [String: String] = [:]
        var written: [URL] = []
        var moved: [Attachment] = []
        for var attachment in unique {
            let value = attachment[keyPath: contents.field]
            if let value, let file = contents.file(value) {
                let url = folder.appending(path: "\(UUID().uuidString).\(fileExtension(attachment.mimeType, contents))")
                do {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    try file.write(to: url, options: .atomic)
                } catch {
                    for url in written { try? manager.removeItem(at: url) }
                    return nil
                }
                written.append(url)
                files[attachment.id] = url.lastPathComponent
                attachment[keyPath: contents.field] = nil
            } else if value == nil, let name = kept[attachment.id], size(of: name, in: folder) != nil {
                files[attachment.id] = name
            } else if value == nil, contents == .bytes, carriesBytes(attachment) {
                continue
            }
            moved.append(attachment)
        }
        return (moved, files)
    }

    /// `attachments` with each one's `contents` read back from the file `files` names for it in
    /// `folder`. A chip whose file is missing or not a bare name in the folder is left out.
    static func readBack(_ attachments: [Attachment], _ contents: Contents = .bytes, files: [String: String], in folder: URL) -> [Attachment] {
        attachments.compactMap { attachment in
            guard let name = files[attachment.id] else { return attachment }
            guard size(of: name, in: folder) != nil,
                  // concurrency-allow: the files a composer kept, read once off the main actor when its chat opens or the app launches
                  let file = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            var attachment = attachment
            attachment[keyPath: contents.field] = contents.value(file)
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
    static func fileExtension(_ mimeType: String, _ contents: Contents = .bytes) -> String {
        if contents == .text { return "txt" }
        return switch mimeType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "application/pdf": "pdf"
        default: "bin"
        }
    }
}
