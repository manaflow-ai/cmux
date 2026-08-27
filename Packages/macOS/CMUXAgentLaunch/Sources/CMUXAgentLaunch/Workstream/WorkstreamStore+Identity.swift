import Foundation

extension WorkstreamStore {
    /// Applies the app-provided workstream identity migration to one item.
    func normalizedWorkstreamItem(_ item: WorkstreamItem) -> WorkstreamItem {
        let normalizedID = workstreamIDNormalizer(item.workstreamId, item.source)
        guard normalizedID != item.workstreamId else { return item }
        return WorkstreamItem(
            id: item.id,
            workstreamId: normalizedID,
            source: item.source,
            kind: item.kind,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            cwd: item.cwd,
            title: item.title,
            status: item.status,
            payload: item.payload,
            context: item.context,
            ppid: item.ppid
        )
    }
}
