extension ContextMenuCatalog {
    /// `entries` with only the rows `keeps` (``ActionRegistry/contextMenuEntries(for:only:)``): a folder or group keeps
    /// only those and goes when none is left; no separator leads, trails or doubles.
    public nonisolated static func keeping(_ entries: [ContextMenuEntry], _ keeps: (ActionID) -> Bool) -> [ContextMenuEntry] {
        var kept: [ContextMenuEntry] = []
        for entry in entries {
            let made: ContextMenuEntry? = switch entry {
            case .separator: kept.isEmpty || kept.last == .separator ? nil : .separator
            case .action(let id), .choices(let id), .submenu(let id, _): keeps(id) ? entry : nil
            case .folder(let folder, let rows): Optional(keeping(rows, keeps)).flatMap { $0.isEmpty ? nil : .folder(folder, $0) }
            case .group(let group, let rows): Optional(keeping(rows, keeps)).flatMap { $0.isEmpty ? nil : .group(group, $0) }
            }
            if let made { kept.append(made) }
        }
        if kept.last == .separator { kept.removeLast() }
        return kept
    }
}
