import Foundation
import Bonsplit
import OSLog

nonisolated private let nativeDragCoordinatorLogger = Logger(
    subsystem: "ai.manaflow.cmux",
    category: "NativeDragCoordinator"
)

@MainActor
final class PaneDropTargetRegistry {
    private struct Entry {
        weak var target: AnyObject?
        let reset: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    nonisolated init() {}

    func register(_ target: AnyObject, reset: @escaping () -> Void) {
        entries[ObjectIdentifier(target)] = Entry(target: target, reset: reset)
    }

    func resetAll() {
        entries = entries.filter { $0.value.target != nil }
        for entry in Array(entries.values) {
            entry.reset()
        }
    }
}

@MainActor
final class NativeDragCoordinator {
    let paneDropTargetRegistry = PaneDropTargetRegistry()

    private(set) var tabDragTransferRegistry: TabDragTransferRegistry
    private var nativeDragEndObserverID: UUID?
    private var hasAdoptedTabDragTransferRegistry = false

    init() {
        tabDragTransferRegistry = TabDragTransferRegistry()
        observeNativeDragEnds(on: tabDragTransferRegistry)
    }

    init(tabDragTransferRegistry: TabDragTransferRegistry) {
        self.tabDragTransferRegistry = tabDragTransferRegistry
        hasAdoptedTabDragTransferRegistry = true
        observeNativeDragEnds(on: tabDragTransferRegistry)
    }

    @discardableResult
    func adopt(tabDragTransferRegistry: TabDragTransferRegistry) -> Bool {
        guard self.tabDragTransferRegistry !== tabDragTransferRegistry else { return true }
        guard !hasAdoptedTabDragTransferRegistry else {
            nativeDragCoordinatorLogger.error(
                "Ignoring a second TabDragTransferRegistry adoption; retaining the registry used by live windows."
            )
            return false
        }
        if let nativeDragEndObserverID {
            self.tabDragTransferRegistry.removeNativeDragEndObserver(nativeDragEndObserverID)
        }
        self.tabDragTransferRegistry = tabDragTransferRegistry
        hasAdoptedTabDragTransferRegistry = true
        observeNativeDragEnds(on: tabDragTransferRegistry)
        return true
    }

    private func observeNativeDragEnds(on registry: TabDragTransferRegistry) {
        nativeDragEndObserverID = registry.addNativeDragEndObserver { [weak self] in
            self?.paneDropTargetRegistry.resetAll()
        }
    }
}
