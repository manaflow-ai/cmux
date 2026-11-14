import CmuxNextSettings
import Foundation
import UniformTypeIdentifiers

extension AgentPaneModel {
    /// The largest file another app may send to a chat: a screenshot or a photo is far smaller. Its
    /// bytes cross to the page as base64, as a draft's chips do (``AgentPaneDraftAttachments``).
    nonisolated static let externalFileLimit = 64 * 1024 * 1024

    /// The files another app sent to this chat (`chat.attach.external`, Send to cmux Chat, an image
    /// opened with cmux or dropped on its Dock icon): `{files: [{name, type, data}]}`, each file's
    /// bytes as base64, for the page to add as a drop's files. Taken once; none when nothing waits.
    ///
    /// Only the App holds such files (``AgentPaneDroppedPaths/hold(external:claimed:)``), so page
    /// script can't name one. Once read they are recorded as an `external` gesture's, so the page's
    /// `chat.attach.dropped` and `chat.attach.source` for them answer as for a drop: a chat on this
    /// Mac links each where it is, and its chip says which app it came from. The person's act in the
    /// other app is the gesture: it leaves the upload credit a chat on another machine streams them
    /// with, and nothing else.
    func takeExternalAttachments() async -> [String: Any] {
        guard let held = droppedPaths.takeExternal() else { return AgentPaneReply.success(["files": [Any]()]) }
        let urls = held.urls
        let read = await Task.detached(priority: .userInitiated) { urls.compactMap(Self.externalFile) }.value
        guard !read.isEmpty else { return AgentPaneReply.success(["files": [Any]()]) }
        let taken = read.map(\.url)
        droppedPaths.stash(taken, kind: .external)
        droppedPaths.stashSource(taken, items: taken.count, claimed: held.claimed, kind: .external)
        transport.gestures.recordUpload()
        return AgentPaneReply.success(["files": read.map { ["name": $0.url.lastPathComponent, "type": $0.type, "data": $0.data] }])
    }

    /// File `url`'s MIME type and bytes as base64, for the page's `{name, type, data}`; nil for a
    /// folder, a file that can't be read or one over ``externalFileLimit``.
    nonisolated static func externalFile(_ url: URL) -> (url: URL, type: String, data: String)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= externalFileLimit,
              // concurrency-allow: one file another app sent, read off the main actor (Task.detached)
              let data = try? Data(contentsOf: url) else { return nil }
        return (url, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "", data.base64EncodedString())
    }

    /// `chat.composer.get`'s answer for this chat: `{session, attachments: [{name, mimeType, bytes,
    /// source}], text}`. `page`: the page's own `{text, attachments}` (``AgentPaneView/composerReadback()``);
    /// without one (an older page, one that did not answer) the chips the chat keeps for its draft
    /// (`kept`) and no text. `source` is the chip's app's name, empty when it has none.
    nonisolated static func composerJSON(session: String?, page: JSONValue?, kept: [AgentPaneWakeState.Attachment]) -> JSONValue {
        let attachments: [JSONValue]
        let text: String
        if case .object(let fields)? = page, case .array(let chips)? = fields["attachments"] {
            text = fields["text"]?.stringValue ?? ""
            attachments = chips.map { chip in
                .object([
                    "name": .string(chip["name"]?.stringValue ?? ""),
                    "mimeType": .string(chip["mimeType"]?.stringValue ?? ""),
                    "bytes": .number(chip["bytes"]?.doubleValue.map { $0.rounded() } ?? 0),
                    "source": .string(chip["source"]?.stringValue ?? ""),
                ])
            }
        } else {
            text = ""
            attachments = kept.map { chip in
                .object(["name": .string(chip.name), "mimeType": .string(chip.mimeType),
                         "bytes": .number(chip.size.rounded()), "source": .string(chip.source?.name ?? "")])
            }
        }
        return .object(["session": session.map(JSONValue.string) ?? .null, "attachments": .array(attachments), "text": .string(text)])
    }
}
