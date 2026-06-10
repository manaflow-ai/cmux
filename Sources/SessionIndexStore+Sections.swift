import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


// MARK: - Section projection and reordering
extension SessionIndexStore {
    /// Returns the sections for the current grouping mode, in the user-saved order.
    func sectionsForCurrentGrouping() -> [IndexSection] {
        if cachedSectionsRevision == sectionsCacheRevision {
            return cachedSections
        }

        let visible = filteredEntriesForCurrentScope()
        let sections: [IndexSection]
        switch grouping {
        case .agent:
            let buckets = Dictionary(grouping: visible, by: { $0.agent.rawValue })
            sections = agentOrder.compactMap { agent in
                guard let entries = buckets[agent.rawValue], !entries.isEmpty else { return nil }
                return IndexSection(
                    key: .agent(agent),
                    title: agent.displayName,
                    icon: .agent(agent),
                    entries: entries
                )
            }
        case .directory:
            let buckets = Dictionary(grouping: visible) { $0.cwd ?? "" }
            // Any cwds that aren't yet in the saved order still need to show
            // up. They get appended by most-recent activity, purely locally,
            // without mutating `directoryOrder` from inside this view-body
            // computation — scheduling a Task here created a state-update
            // feedback loop that pegged the main thread at 100% CPU.
            // Persistent backfill happens via `backfillDirectoryOrderFromEntries`,
            // called from `reload()` and `grouping.didSet`.
            let knownPaths = Set(directoryOrder)
            let unknownSorted = buckets.keys
                .filter { !knownPaths.contains($0) }
                .sorted { lhs, rhs in
                    let lMax = buckets[lhs]?.map(\.modified).max() ?? .distantPast
                    let rMax = buckets[rhs]?.map(\.modified).max() ?? .distantPast
                    return lMax > rMax
                }
            sections = (directoryOrder + unknownSorted)
                .filter { buckets[$0] != nil }
                .map { path in
                    IndexSection(
                        key: .directory(path.isEmpty ? nil : path),
                        title: directoryDisplayName(path),
                        icon: .folder,
                        entries: buckets[path] ?? []
                    )
                }
        }

        cachedSections = sections
        cachedSectionsRevision = sectionsCacheRevision
        return sections
    }

    private func filteredEntriesForCurrentScope() -> [SessionEntry] {
        guard scopeToCurrentDirectory, let dir = normalizedDirectory(currentDirectory) else {
            return entries
        }
        return entries.filter { entry in
            guard let cwd = normalizedDirectory(entry.cwd) else { return false }
            return cwd == dir || cwd.hasPrefix(dir + "/")
        }
    }

    private func directoryDisplayName(_ path: String) -> String {
        if path.isEmpty {
            return String(localized: "sessionIndex.directory.unknown", defaultValue: "(no folder)")
        }
        return (path as NSString).lastPathComponent
    }

    /// Move `key` so it lands immediately before `referenceKey` in the
    /// persisted order (or at the end if `referenceKey` is nil). Anchoring
    /// to a neighbor key (rather than a positional index) means scope filters
    /// can hide some sections without corrupting reorders: hidden sections
    /// keep their relative position to their visible neighbors.
    func moveSection(_ key: SectionKey, before referenceKey: SectionKey?) {
        switch grouping {
        case .agent:
            guard key.raw.hasPrefix("agent:"),
                  let agent = SessionAgent(rawValue: String(key.raw.dropFirst("agent:".count))) else { return }
            guard let oldIndex = agentOrder.firstIndex(where: { $0.rawValue == agent.rawValue }) else { return }
            var next = agentOrder
            let moved = next.remove(at: oldIndex)
            if let referenceKey,
               referenceKey.raw.hasPrefix("agent:"),
               let refAgent = SessionAgent(rawValue: String(referenceKey.raw.dropFirst("agent:".count))),
               let refIndex = next.firstIndex(where: { $0.rawValue == refAgent.rawValue }) {
                next.insert(moved, at: refIndex)
            } else {
                next.append(moved)
            }
            if next != agentOrder { agentOrder = next }
        case .directory:
            guard key.raw.hasPrefix("dir:") else { return }
            let path = String(key.raw.dropFirst("dir:".count))
            guard let oldIndex = directoryOrder.firstIndex(of: path) else { return }
            var next = directoryOrder
            next.remove(at: oldIndex)
            if let referenceKey,
               referenceKey.raw.hasPrefix("dir:") {
                let refPath = String(referenceKey.raw.dropFirst("dir:".count))
                if let refIndex = next.firstIndex(of: refPath) {
                    next.insert(path, at: refIndex)
                } else {
                    next.append(path)
                }
            } else {
                next.append(path)
            }
            if next != directoryOrder { directoryOrder = next }
        }
    }

}
