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

    init(
        containerResolver: @escaping ContainerResolver = { context in
            AppDelegate.shared?.paneDropContainer(for: context)
        },
        sourceResolver: PaneTransferSourceResolver = PaneTransferSourceResolver()
    ) {
        self.containerResolver = containerResolver
        self.sourceResolver = sourceResolver
    }

    /// Pins pane ownership at drag entry so every later phase uses the same owner.
    func begin(context: PaneDropContext) {
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
        guard let transfer = PaneDragTransfer.decode(from: pasteboard) else {
            return .notTransfer
        }
        guard let source = sourceResolver.source(for: transfer),
              let container = container(for: context),
              container.canPerformPortalPaneDrop(transfer, source: source) else {
            return .rejected
        }
        let zone = container.portalPaneDropZone(
            tabId: transfer.tabId,
            sourcePaneId: transfer.sourcePaneId,
            targetPane: context.paneId,
            proposedZone: proposedZone
        )
        return .accepted(Plan(
            context: context,
            transfer: transfer,
            source: source,
            zone: zone
        ))
    }

    /// Executes a previously accepted transfer through the same pane owner.
    func perform(_ plan: Plan) -> Bool {
        guard let container = container(for: plan.context) else { return false }
        return container.performPortalPaneDrop(
            tabId: plan.transfer.tabId,
            sourcePaneId: plan.transfer.sourcePaneId,
            targetPane: plan.context.paneId,
            zone: plan.zone
        )
    }

    /// Releases the owner when the drag or target context ends.
    func clear() {
        activeContainer = nil
        activeContext = nil
    }
}
