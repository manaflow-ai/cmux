import Foundation

/// Mac-local sidebar preferences. Membership and session topology always come
/// from the catalog; these records only order stable identities within a parent.
struct CloudSidebarOrganizationState: Codable, Equatable {
    var groups: [String: CloudSidebarOrganizationGroup] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case groups, orders, pins }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.groups) {
            groups = try values.decode([String: CloudSidebarOrganizationGroup].self, forKey: .groups)
        } else {
            // Early organization drafts used the same preference key. Import
            // their stable IDs once; all subsequent writes use the current schema.
            let orders = try values.decode([String: [String]].self, forKey: .orders)
            let pins = try values.decode(Set<String>.self, forKey: .pins)
            groups = orders.mapValues { CloudSidebarOrganizationGroup(order: $0, pinned: pins.intersection($0)) }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(groups, forKey: .groups)
    }

    func ordered(_ ids: [String], parent: String) -> [String] {
        guard let group = groups[parent] else { return ids }
        let present = Set(ids)
        let remembered = Set(group.order)
        var seen = Set<String>()
        let saved = group.order.filter { present.contains($0) && seen.insert($0).inserted }
        let discovered = ids.filter { !remembered.contains($0) }
        // At the outline root every eligible row is a Cloud machine. Newly
        // discovered machines replace pending rows ahead of ordinary saved rows.
        let order = parent.isEmpty ? discovered + saved : saved + discovered
        return order.filter { group.pinned.contains($0) } + order.filter { !group.pinned.contains($0) }
    }

    func isPinned(_ id: String, parent: String) -> Bool {
        groups[parent]?.pinned.contains(id) == true
    }

    mutating func apply(_ action: CloudSidebarOrganizationAction, id: String, siblings: [String], parent: String) -> Bool {
        guard siblings.contains(id) else { return false }
        var group = groups[parent] ?? CloudSidebarOrganizationGroup()
        var order = ordered(siblings, parent: parent)
        let wasPinned = group.pinned.contains(id)
        switch action {
        case .pin, .unpin:
            let pinned = action == .pin
            guard pinned != wasPinned else { return false }
            if pinned { group.pinned.insert(id) } else { group.pinned.remove(id) }
            order.removeAll { $0 == id }
            let boundary = order.prefix { group.pinned.contains($0) }.count
            order.insert(id, at: boundary)
        case .up, .down, .top, .before, .after:
            let peers = order.filter { group.pinned.contains($0) == wasPinned }
            guard let index = peers.firstIndex(of: id) else { return false }
            let target: String
            let after: Bool
            switch action {
            case .up:
                guard index > 0 else { return false }
                target = peers[index - 1]; after = false
            case .down:
                guard index + 1 < peers.count else { return false }
                target = peers[index + 1]; after = true
            case .top:
                guard let first = peers.first, first != id else { return false }
                target = first; after = false
            case .before(let neighbor): target = neighbor; after = false
            case .after(let neighbor): target = neighbor; after = true
            default: return false
            }
            guard target != id, peers.contains(target) else { return false }
            order.removeAll { $0 == id }
            guard let targetIndex = order.firstIndex(of: target) else { return false }
            order.insert(id, at: targetIndex + (after ? 1 : 0))
        }
        // Missing rows may be a disconnected machine or a temporarily empty
        // workspace. Keep their slots until authoritative deletion is known.
        let present = Set(siblings)
        var remaining = order.makeIterator()
        var seen = Set<String>()
        var merged = group.order.filter { seen.insert($0).inserted }.map { present.contains($0) ? (remaining.next() ?? $0) : $0 }
        merged.append(contentsOf: remaining)
        group.order = merged
        guard groups[parent] != group else { return false }
        groups[parent] = group
        return true
    }
}
