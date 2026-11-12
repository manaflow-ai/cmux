import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// One window's request to reveal the workspace its creation flow selected.
struct CloudWorkspaceCreationReveal: Equatable {
    let token: UUID
    var machine: SurfaceMachineID?
    var remoteWorkspaceID: String?
    var isWithdrawn = false

    /// The Cloud tree row, known once the daemon's receipt names the workspace.
    var nodeID: String? {
        guard let machine, let remoteWorkspaceID else { return nil }
        return CloudTreeNodeBuilder.nodeID(workspace: remoteWorkspaceID, machine: machine)
    }
}

/// The latest creation reveal per window, published to that window's Cloud tree.
///
/// A flow begins a reveal when its window selects the new local workspace,
/// completes it once the daemon's receipt names the remote workspace, and
/// withdraws it when the create fails, is cancelled or is rejected. The tree
/// decides whether the selection is still its to move.
@MainActor @Observable
final class CloudWorkspaceCreationReveals {
    private struct Entry {
        weak var manager: TabManager?
        var reveal: CloudWorkspaceCreationReveal
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func reveal(for manager: TabManager?) -> CloudWorkspaceCreationReveal? {
        guard let manager, let entry = entries[ObjectIdentifier(manager)], entry.manager === manager else { return nil }
        return entry.reveal
    }

    /// Starts a reveal in the window that selected the new workspace; a newer
    /// create in the same window replaces it.
    @discardableResult
    func begin(in manager: TabManager) -> UUID {
        entries = entries.filter { $0.value.manager != nil }
        let token = UUID()
        entries[ObjectIdentifier(manager)] = Entry(manager: manager, reveal: .init(token: token))
        return token
    }

    func receive(_ token: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String) {
        update(token) {
            $0.machine = machine
            $0.remoteWorkspaceID = remoteWorkspaceID
        }
    }

    /// Completes a reveal from the local workspace's Cloud binding.
    func receive(_ token: UUID, revealing workspace: Workspace) {
        guard let binding = workspace.cloudVMBinding, let remoteWorkspaceID = binding.remoteWorkspaceID,
              !binding.vmID.isEmpty, !remoteWorkspaceID.isEmpty else {
            withdraw(token)
            return
        }
        receive(token, machine: SurfaceMachineID(rawValue: binding.vmID), remoteWorkspaceID: remoteWorkspaceID)
    }

    /// Runs a create that selects its workspace only when it finishes. `token`
    /// comes from `begin(in:)` before the create starts, so a selection made
    /// while it runs still wins; the reveal then follows the workspace `body`
    /// selected, or is withdrawn. Taking the token rather than the window's
    /// manager keeps the create from holding a closed window alive.
    func revealing(_ token: UUID?, _ body: @MainActor () async throws -> Workspace?) async rethrows {
        var selected: Workspace?
        defer {
            if let token {
                if let selected { receive(token, revealing: selected) } else { withdraw(token) }
            }
        }
        selected = try await body()
    }

    func withdraw(_ token: UUID) {
        update(token) { $0.isWithdrawn = true }
    }

    private func update(_ token: UUID, _ body: (inout CloudWorkspaceCreationReveal) -> Void) {
        guard let key = entries.first(where: { $0.value.reveal.token == token })?.key,
              var entry = entries[key], !entry.reveal.isWithdrawn else { return }
        body(&entry.reveal)
        entries[key] = entry
    }
}
