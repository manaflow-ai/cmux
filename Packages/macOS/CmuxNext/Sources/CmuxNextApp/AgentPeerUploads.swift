import CmuxNextAgentActivity
import CmuxNextAgentPane
import Foundation

/// Files the person drops or pastes into a chat whose agent runs on an ssh peer (acpmux peering:
/// this Mac's acpmux mirrors the chat, named `huge-blue/<name>`) that the composer can't attach as
/// a prompt block. The page sends their bytes (``AgentPaneUpload``, the same `chat.upload` a local
/// or Cloud chat's upload uses), and only for such a chat, with a real gesture in its pane, the
/// app sends each one through this Mac's acpmux to the daemon that owns the chat
/// (`_acpmux/file_put`), which saves it owner-only on that machine and answers where. The composer
/// puts those paths in the prompt and the agent opens them there. An acpmux from before that
/// method, here or on the peer, answers `unsupported`, so the composer keeps its own note.
@MainActor
struct AgentPeerUploads {
    /// The peer chat tab `tab` shows: its session, the peer's name and the pane's acpmux.
    struct Target {
        var session: String
        var machine: String
        var host: any AgentPaneHostProviding
    }

    /// The upload for chat tab `tab`, nil unless it is a peer's chat (``target(tab:services:)``).
    static func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard let target = target(tab: tab, services: services) else { return nil }
        return { files in
            await upload(files, machine: target.machine) { name, data in
                try await target.host.putFile(sessionId: target.session, name: name, data: data)
            }
        }
    }

    /// Tab `tab`'s chat when its pane attaches to this Mac's acpmux and that acpmux lists its
    /// session as a peer's (``AgentActivityLane/peer``, from the same `_acpmux/watch` the page
    /// reads its chat's `peer` from).
    static func target(tab: String, services: AppServices) -> Target? {
        let tabs = services.agentTabs
        guard tabs.gitLink?(tab)?.isLocal == true, let session = tabs.session(of: tab),
              let machine = peer(of: session, lanes: AgentLaneStore.shared) else { return nil }
        // The pane's own acpmux (`AgentTabStore.view(for:)`).
        return Target(session: session, machine: machine, host: tabs.localSessionHost ?? tabs.host)
    }

    /// The acpmux peer that runs `session`, nil for a chat of this Mac's acpmux (or one it does
    /// not list).
    static func peer(of session: String, lanes: AgentLaneStore) -> String? {
        lanes.links(session)?.peer.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The reply to the page's upload: each file put in turn with `put`, which answers its path on
    /// `machine`. A file past ``AgentPaneUpload/maximumPeerFileBytes`` is refused before any is sent.
    static func upload(_ files: [AgentPaneUpload], machine: String,
                       put: (_ name: String, _ data: Data) async throws -> String) async -> [String: Any] {
        guard files.allSatisfy({ $0.data.count <= AgentPaneUpload.maximumPeerFileBytes }) else {
            return AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(machine))
        }
        var uploads: [[String: Any]] = []
        for file in files {
            do {
                let path = try await put(file.name, file.data)
                uploads.append(["name": file.name, "path": path])
            } catch {
                return reply(AgentPaneFilePutFailure(error), machine: machine)
            }
        }
        return AgentPaneReply.success(["uploads": uploads])
    }

    static func reply(_ failure: AgentPaneFilePutFailure, machine: String) -> [String: Any] {
        switch failure {
        // The page's own note: this chat takes no uploads (cloudUploads.ts `NOT_TAKEN`).
        case .unsupported: AgentPaneReply.failure(code: "unsupported", message: AgentPeerUploadStrings.failed(machine))
        case .tooLarge: AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(machine))
        case .failed: AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(machine))
        }
    }
}

/// A peer chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings
/// beside the Cloud and local chat uploads'.
enum AgentPeerUploadStrings {
    static func failed(_ machine: String) -> String {
        String(localized: "chat.upload.peerFailed", defaultValue: "Couldn't send the file to \(machine).", table: "Cloud", bundle: .module)
    }
    static func tooLarge(_ machine: String) -> String {
        String(localized: "chat.upload.peerTooLarge", defaultValue: "This file is too large to send to \(machine).", table: "Cloud", bundle: .module)
    }
}
