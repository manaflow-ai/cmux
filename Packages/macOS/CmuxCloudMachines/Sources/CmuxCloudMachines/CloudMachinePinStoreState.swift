import Foundation

/// Codable state for one account/team scope: the remembered machine order and the pinned identities.
struct CloudMachinePinStoreState: Codable, Equatable {
    /// Machine identities in chosen order, initially first-seen.
    var order: [String] = []
    /// Machine identities the person pinned in this scope.
    var pinned: Set<String> = []

    func ordered(_ visible: [String]) -> [String] {
        let visibleSet = Set(visible)
        var seen = Set<String>()
        let ids = order.filter { visibleSet.contains($0) && seen.insert($0).inserted }
            + visible.filter { seen.insert($0).inserted }
        return ids.filter { pinned.contains($0) } + ids.filter { !pinned.contains($0) }
    }

    /// Plans the same mutation for drag validation and commit without writing
    /// during hover. Absent identities keep their relative order.
    func moving(_ move: CloudMachineMove, machineID: String, visible: [String]) -> Self? {
        let current = ordered(visible)
        let peers = current.filter { pinned.contains($0) == pinned.contains(machineID) }
        guard !machineID.isEmpty, let index = peers.firstIndex(of: machineID) else { return nil }
        let target: String
        let after: Bool
        switch move {
        case .up:
            guard index > 0 else { return nil }
            target = peers[index - 1]; after = false
        case .down:
            guard index + 1 < peers.count else { return nil }
            target = peers[index + 1]; after = true
        case .top:
            guard let first = peers.first else { return nil }
            target = first; after = false
        case .before(let id): target = id; after = false
        case .after(let id): target = id; after = true
        }
        guard target != machineID, peers.contains(target) else { return nil }
        var preview = current.filter { $0 != machineID }
        guard let targetIndex = preview.firstIndex(of: target) else { return nil }
        preview.insert(machineID, at: targetIndex + (after ? 1 : 0))
        guard preview != current else { return nil }

        var next = self
        var seen = Set<String>()
        next.order = (order + current).filter { $0 != machineID && seen.insert($0).inserted }
        guard let savedIndex = next.order.firstIndex(of: target) else { return nil }
        next.order.insert(machineID, at: savedIndex + (after ? 1 : 0))
        return next
    }
}
