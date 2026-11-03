import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation

/// Agent-notification originals use the same file stream as the chat composer.
/// Build the prompt only after every upload succeeds; never silently omit a picked file.
enum PushReplyAttachments {
    @MainActor
    static func blocks(text: String, names: [String], outbox: PushOutbox?, link: (any MacLink)?) async throws -> [JSONValue] {
        let attachments = try await Task.detached(priority: .userInitiated) {
            try files(names, outbox: outbox)
        }.value
        var uploaded: [String: String] = [:]
        for attachment in attachments {
            guard let link else { throw LinkError(code: "offline", message: "Connect to send attachments.") }
            guard let url = attachment.fileURL else { throw PushOutbox.Refused() }
            uploaded[attachment.id] = try await LinkUpload.upload(fileAt: url, name: attachment.name, cwd: nil, over: link)
        }
        return AcpmuxSessionSource.promptBlocks(text: text, attachments: attachments, uploaded: uploaded)
    }

    nonisolated static func files(_ names: [String], outbox: PushOutbox?) throws -> [AgentAttachment] {
        guard !names.isEmpty else { return [] }
        guard let outbox else { throw LinkUpload.Failure(code: "unreadable", message: "Couldn't open notification attachments.") }
        return try names.map { name in
            guard (name as NSString).lastPathComponent == name, !name.hasPrefix(".") else { throw PushOutbox.Refused() }
            let url = outbox.attachments.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw LinkUpload.Failure(code: "unreadable", message: "Couldn't read \(name) on this iPhone.")
            }
            return AgentAttachment(kind: .file, name: name, fileURL: url, byteCount: size)
        }
    }
}
