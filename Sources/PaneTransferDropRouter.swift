import AppKit
import Bonsplit

/// Resolves and performs pane-transfer drops through the target pane's owner.
@MainActor
final class PaneTransferDropRouter {
    /// The complete acceptance result for one pane-transfer payload.
    enum Resolution: Equatable {
        case notTransfer
        case rejected
        case accepted(Plan)
    }

    /// An immutable transfer accepted by one authoritative pane container.
    struct Plan: Equatable {
        let context: PaneDropContext
        let transfer: PaneDragTransfer
        let source: PaneTransferSourceResolver.Source
        let zone: DropZone
    }

    typealias ContainerResolver = @MainActor (PaneDropContext) -> (any PaneDropContainer)?

    private let containerResolver: ContainerResolver
    private let sourceResolver: PaneTransferSourceResolver
    private weak var activeContainer: (any PaneDropContainer)?
    private var activeContext: PaneDropContext?
    private var activePlan: Plan?

    init(
        containerResolver: @escaping ContainerResolver = { context in
            AppDelegate.shared?.paneDropContainer(for: context)
        },
        sourceResolver: PaneTransferSourceResolver? = nil
    ) {
        self.containerResolver = containerResolver
        self.sourceResolver = sourceResolver ?? PaneTransferSourceResolver()
    }

    /// Pins pane ownership at drag entry so every later phase uses the same owner.
    func begin(context: PaneDropContext) {
        activePlan = nil
        activeContainer = containerResolver(context)
        activeContext = activeContainer == nil ? nil : context
    }

    /// Returns the cached owner, resolving it when routing begins after drag entry.
    func container(for context: PaneDropContext) -> (any PaneDropContainer)? {
        if activeContext == context {
            return activeContainer
        }
        begin(context: context)
        return activeContainer
    }

    /// Applies the container's single acceptance and zone policy to a transfer.
    func resolve(
        pasteboard: NSPasteboard,
        context: PaneDropContext,
        proposedZone: DropZone
    ) -> Resolution {
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboard.types) else {
            activePlan = nil
            return .notTransfer
        }
        guard let transfer = sourceResolver.transfer(from: pasteboard) else {
            activePlan = nil
            return .rejected
        }
        guard let container = container(for: context) else {
            activePlan = nil
            return .rejected
        }
        let source: PaneTransferSourceResolver.Source
        if let accepted = activePlan,
           accepted.context == context,
           accepted.transfer == transfer {
            source = accepted.source
        } else if let resolved = sourceResolver.source(for: transfer) {
            source = resolved
        } else {
            activePlan = nil
            return .rejected
        }
        guard container.canPerformPortalPaneDrop(transfer, source: source) else {
            activePlan = nil
            return .rejected
        }
        let zone = container.portalPaneDropZone(
            tabId: transfer.tabId,
            sourcePaneId: transfer.sourcePaneId,
            targetPane: context.paneId,
            proposedZone: proposedZone
        )
        let plan = Plan(
            context: context,
            transfer: transfer,
            source: source,
            zone: zone
        )
        activePlan = plan
        return .accepted(plan)
    }

    /// Executes a previously accepted transfer through the same pane owner.
    func perform(_ plan: Plan, pasteboard: NSPasteboard) -> Bool {
        guard activePlan == plan,
              let container = container(for: plan.context) else { return false }
        let handled = container.performPortalPaneDrop(
            tabId: plan.transfer.tabId,
            sourcePaneId: plan.transfer.sourcePaneId,
            targetPane: plan.context.paneId,
            zone: plan.zone,
            source: plan.source
        )
        if handled {
            sourceResolver.finishAcceptedDrop(
                plan.source,
                id: plan.transfer.tabId,
                pasteboard: pasteboard
            )
        }
        activePlan = nil
        return handled
    }

    /// Releases the owner when the drag or target context ends.
    func clear() {
        activePlan = nil
        activeContainer = nil
        activeContext = nil
    }
}
