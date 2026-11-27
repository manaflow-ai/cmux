import AppKit
import Bonsplit

/// Describes a whole sidebar tool using Bonsplit's process-local drag lease.
/// The mode lives in registered metadata, never in a terminal resource or title.
struct RightSidebarToolDragPayload {
    let mode: RightSidebarMode

    init(mode: RightSidebarMode) {
        self.mode = mode
    }

    init?(transfer: TabDragTransfer) {
        let prefix = "rightSidebarTool:"
        guard let kind = transfer.tab.kind, kind.hasPrefix(prefix),
              let mode = RightSidebarMode(rawValue: String(kind.dropFirst(prefix.count))),
              mode.canOpenAsPane else { return nil }
        self.mode = mode
    }

    @MainActor
    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        guard mode.canOpenAsPane, mode.isAvailable() else { return nil }
        let id = UUID()
        return registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: id), title: mode.label,
                             icon: mode.symbolName, kind: "rightSidebarTool:\(mode.rawValue)"),
            sourcePaneId: PaneID(id: id)
        ))
    }
}
