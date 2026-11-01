import CmuxHomeCore
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// Delete Chief (next to Archive Chief on a Chief's Home row): the Chief goes for good. A cloud
/// Chief through `chief.delete` (its record becomes a tombstone, its tokens and sandboxes end);
/// one of this Mac's Chiefs through the owner's `chief.profile.delete` (its brain stops, its
/// sessions end, its brain folder goes). Never the default Chief: the row offers no Delete for it,
/// and both owners refuse it (`chief_is_default`).
extension HomeService {
    /// A Chief the person may delete: its participant id and the name the question shows.
    struct DeletableChief: Equatable {
        var id: String
        var name: String
        /// One of the signed-in account's cloud Chiefs, else one of this Mac's.
        var cloud: Bool
    }

    /// The Chief behind a Chief row that Delete Chief applies to; nil for the default Chief, a row
    /// that is not a Chief's, or a cloud conversation whose Chief is not one of mine.
    func deletableChief(of row: InboxRow) -> DeletableChief? {
        guard row.kind == .chief else { return nil }
        let me = homeStore.me?.id
        if let record = row.summary.participants.lazy.compactMap({ self.directory.chief(for: $0.id) }).first {
            return record.isDefault ? nil : DeletableChief(id: record.id, name: record.name, cloud: true)
        }
        guard !isCloudConversation(row.id),
              let agent = row.summary.participants.first(where: { $0.id != me && $0.isChief }),
              agent.id.rawValue != Self.mux.id, !directory.archivedChiefs.contains(agent.id.rawValue) else { return nil }
        return DeletableChief(id: agent.id.rawValue, name: agent.displayName, cloud: false)
    }

    /// The Chief `id` names on a listed Chief row, for the action's question and its run.
    func deletableChief(id: String) -> DeletableChief? {
        homeStore.rows.lazy.compactMap { self.deletableChief(of: $0) }.first { $0.id == id }
    }

    /// Deletes `id`; nil when it worked, else why not. Only a Chief the list shows now (the one
    /// its question named): one that is not resolved is refused, never deleted unasked.
    func deleteChief(_ id: String) async -> String? {
        guard let chief = deletableChief(id: id) else {
            return id == Self.mux.id || directory.chief(for: ParticipantID(id))?.isDefault == true
                ? HomeStrings.deleteDefaultChief : HomeStrings.deleteFailed
        }
        return chief.cloud ? await deleteCloudChief(id) : await deleteLocalChief(id)
    }

    private func deleteCloudChief(_ id: String) async -> String? {
        do {
            try await directory.deleteChief(id)
            return nil
        } catch FeedServiceError.owner(let code, let message) {
            return code == "chief_is_default" ? HomeStrings.deleteDefaultChief : message
        } catch {
            return HomeStrings.deleteFailed
        }
    }

    /// `chief.profile.delete` on the app's trusted connection to this Mac's Chief owner (the
    /// person's own call, as New Chief's create is).
    private func deleteLocalChief(_ id: String) async -> String? {
        guard let connection else { return HomeStrings.deleteFailed }
        let params: [String: JSONValue] = ["chief": .string(id), "machine": .string("current"), "session": .string("current")]
        do {
            _ = try await ResourceRelayClient(connection: connection).send(
                operation: "chief.profile.delete", params: params, idempotencyKey: "home-chief-delete-" + id)
            directory.deletedLocalChiefs.insert(id)
            return nil
        } catch DaemonError.command(_, let message, _, let details, _) {
            // The owner's refusal names its reason in the details (`operation.failed`).
            if case .object(let details)? = details, details["reason"] == .string("chief_is_default") {
                return HomeStrings.deleteDefaultChief
            }
            return message.isEmpty ? HomeStrings.deleteFailed : message
        } catch {
            return HomeStrings.deleteFailed
        }
    }
}
