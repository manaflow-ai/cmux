import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread when any presence entry for a machine
    /// changes. `userInfo[CloudPresenceStore.machineIDKey]` names the machine.
    static let cloudPresenceDidChange = Notification.Name("cmux.cloudPresenceDidChange")
}

/// The Mac-side presence model: which local panes mirror which daemon
/// surfaces, one presence link per machine, and the latest entry per remote
/// client. Overlays read `entries(forPane:)`; the Ghostty view publishes
/// through `publish`.
@MainActor
final class CloudPresenceStore {
    static let shared = CloudPresenceStore()
    static let machineIDKey = "machineID"

    struct Pane: Equatable {
        var machineID: String
        var remoteSurfaceID: UInt64
        var socketPath: String
    }

    private var panes: [UUID: Pane] = [:]
    private var links: [String: CloudPresenceLink] = [:]
    /// machineID -> client -> entry. Cleared entries are removed.
    private var entries: [String: [UInt64: CloudPresenceEntry]] = [:]
    private var lastPublishedPane: UUID?

    /// The label other clients see next to this Mac's pointer.
    var clientName: String = {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }()

    // MARK: Pane registry

    func registerPane(panelID: UUID, machineID: String, remoteSurfaceID: UInt64, socketPath: String) {
        panes[panelID] = Pane(machineID: machineID, remoteSurfaceID: remoteSurfaceID, socketPath: socketPath)
        ensureLink(machineID: machineID, socketPath: socketPath)
    }

    func updateRemoteSurfaceID(panelID: UUID, remoteSurfaceID: UInt64) {
        guard var pane = panes[panelID], pane.remoteSurfaceID != remoteSurfaceID else { return }
        pane.remoteSurfaceID = remoteSurfaceID
        panes[panelID] = pane
    }

    func updateSocketPath(panelID: UUID, socketPath: String) {
        guard var pane = panes[panelID], pane.socketPath != socketPath else { return }
        pane.socketPath = socketPath
        panes[panelID] = pane
        ensureLink(machineID: pane.machineID, socketPath: socketPath)
    }

    func unregisterPane(panelID: UUID) {
        guard let pane = panes.removeValue(forKey: panelID) else { return }
        if lastPublishedPane == panelID {
            lastPublishedPane = nil
            links[pane.machineID]?.clear()
        }
        if !panes.values.contains(where: { $0.machineID == pane.machineID }) {
            links.removeValue(forKey: pane.machineID)?.stop()
            if entries.removeValue(forKey: pane.machineID) != nil {
                post(machineID: pane.machineID)
            }
        }
    }

    func isPresencePane(_ panelID: UUID) -> Bool {
        panes[panelID] != nil
    }

    // MARK: Reading

    /// Live entries from other clients that point at this pane's surface.
    func entries(forPane panelID: UUID) -> [CloudPresenceEntry] {
        guard let pane = panes[panelID], let machineEntries = entries[pane.machineID] else { return [] }
        return machineEntries.values
            .filter { $0.surface == pane.remoteSurfaceID }
            .sorted { $0.client < $1.client }
    }

    func machineID(forPane panelID: UUID) -> String? {
        panes[panelID]?.machineID
    }

    // MARK: Publishing

    func publish(panelID: UUID, pointer: CloudPresenceAnchor?, highlight: CloudPresenceHighlight?) {
        guard let pane = panes[panelID] else { return }
        if let previous = lastPublishedPane, previous != panelID,
           let previousPane = panes[previous], previousPane.machineID != pane.machineID {
            links[previousPane.machineID]?.clear()
        }
        lastPublishedPane = panelID
        ensureLink(machineID: pane.machineID, socketPath: pane.socketPath)
            .publish(surfaceID: pane.remoteSurfaceID, pointer: pointer, highlight: highlight)
    }

    func clear(panelID: UUID) {
        guard let pane = panes[panelID], lastPublishedPane == panelID else { return }
        lastPublishedPane = nil
        links[pane.machineID]?.clear()
    }

    // MARK: Links

    @discardableResult
    private func ensureLink(machineID: String, socketPath: String) -> CloudPresenceLink {
        if let link = links[machineID], link.socketPath == socketPath, link.phase != .disconnected {
            return link
        }
        links[machineID]?.stop()
        let link = CloudPresenceLink(
            machineID: machineID,
            socketPath: socketPath,
            clientName: clientName,
            onEntry: { [weak self] entry in self?.apply(entry, machineID: machineID) },
            onPhaseChange: { [weak self] link in self?.linkPhaseChanged(link) }
        )
        links[machineID] = link
        return link
    }

    private func linkPhaseChanged(_ link: CloudPresenceLink) {
        guard link.phase == .disconnected, links[link.machineID] === link else { return }
        // Remote pointers are meaningless without the stream; drop them and
        // let the next register/publish re-dial.
        if entries.removeValue(forKey: link.machineID) != nil {
            post(machineID: link.machineID)
        }
    }

    private func apply(_ entry: CloudPresenceEntry, machineID: String) {
        var machineEntries = entries[machineID] ?? [:]
        if let existing = machineEntries[entry.client], existing.generation >= entry.generation {
            return
        }
        if entry.isCleared {
            guard machineEntries.removeValue(forKey: entry.client) != nil else { return }
        } else {
            machineEntries[entry.client] = entry
        }
        entries[machineID] = machineEntries
        post(machineID: machineID)
    }

    private func post(machineID: String) {
        NotificationCenter.default.post(
            name: .cloudPresenceDidChange,
            object: self,
            userInfo: [Self.machineIDKey: machineID]
        )
    }
}
