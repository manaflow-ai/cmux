internal import CmuxTerminalBackend
internal import Foundation

typealias BackendOnlyFocusActionSubmitter = @MainActor @Sendable (
    BackendOnlyFocusAction
) async -> BackendOnlyFocusActionReceipt

/// Main-actor bridge between AppKit first responder and daemon navigation.
///
/// First responder is presentation-local. Active pane styling is daemon-owned
/// and changes only through monotonic authoritative publications or applied
/// action receipts. Registration order never chooses a fallback terminal.
@MainActor
final class BackendOnlyFocusCoordinator {
    static let maximumRegisteredSlotCount = 256

    private typealias Registration = BackendOnlyFocusRegistration
    private typealias AuthorityFenceOrder = BackendOnlyFocusAuthorityFenceOrder

    private var registrations: [BackendOnlyProjectionSlotID: Registration] = [:]
    private let submitAction: BackendOnlyFocusActionSubmitter
    private var nextActionID: UInt64 = 1
    private var newestRequestedActionID: UInt64 = 0

    private(set) var authoritativeActiveSlotID: BackendOnlyProjectionSlotID?
    private(set) var authorityFence: BackendOnlyProjectionRuntimeFence?
    private(set) var firstResponderOwnedSlotID: BackendOnlyProjectionSlotID?
    private(set) var isWindowKey = false

    var registeredSlotCount: Int {
        registrations.count
    }

    init(submitAction: @escaping BackendOnlyFocusActionSubmitter) {
        self.submitAction = submitAction
        registrations.reserveCapacity(Self.maximumRegisteredSlotCount)
    }

    /// Registers or replaces one exact slot without selecting it by position.
    @discardableResult
    func register(
        slotID: BackendOnlyProjectionSlotID,
        content: BackendOnlyFocusSlotContent,
        requestFirstResponder: @escaping @MainActor () -> Bool
    ) -> Bool {
        guard registrations[slotID] != nil
            || registrations.count < Self.maximumRegisteredSlotCount
        else {
            return false
        }
        registrations[slotID] = Registration(
            content: content,
            requestFirstResponder: requestFirstResponder
        )
        if !content.isTerminal, firstResponderOwnedSlotID == slotID {
            firstResponderOwnedSlotID = nil
        }
        if slotID == authoritativeActiveSlotID {
            reconcileProgrammaticFocus()
        }
        return true
    }

    /// Drops only local responder ownership. Daemon active-pane state remains.
    func unregister(slotID: BackendOnlyProjectionSlotID) {
        registrations.removeValue(forKey: slotID)
        if firstResponderOwnedSlotID == slotID {
            firstResponderOwnedSlotID = nil
        }
    }

    /// Updates key-window eligibility without creating a daemon mutation.
    func setWindowKey(_ isKey: Bool) {
        guard isWindowKey != isKey else { return }
        isWindowKey = isKey
        if isKey {
            reconcileProgrammaticFocus()
        } else {
            firstResponderOwnedSlotID = nil
        }
    }

    /// Installs one monotonic authoritative active-pane publication.
    @discardableResult
    func installAuthoritativeActiveSlot(
        _ slotID: BackendOnlyProjectionSlotID?,
        fence incomingFence: BackendOnlyProjectionRuntimeFence
    ) -> Bool {
        guard Self.isValid(incomingFence),
              slotID.map({
                  $0.logicalPresentationID == incomingFence.logicalPresentationID
              }) ?? true else { return false }
        if let authorityFence {
            guard compare(incomingFence, with: authorityFence) == .newer else {
                return false
            }
        }
        authorityFence = incomingFence
        authoritativeActiveSlotID = slotID
        if firstResponderOwnedSlotID != slotID {
            firstResponderOwnedSlotID = nil
        }
        reconcileProgrammaticFocus()
        return true
    }

    func isAuthoritativelyActive(_ slotID: BackendOnlyProjectionSlotID) -> Bool {
        authoritativeActiveSlotID == slotID
    }

    /// Handles a pointer focus gesture without optimistically changing styling.
    ///
    /// A terminal may claim AppKit first responder immediately. The ordered
    /// absolute action selects a tab before activating its pane when both are
    /// required. Only the newest exact applied receipt changes authority.
    func pointerClick(
        slotID: BackendOnlyProjectionSlotID,
        desiredSurfaceID explicitSurfaceID: SurfaceID? = nil
    ) async -> BackendOnlyFocusPointerResult {
        guard let registration = registrations[slotID] else {
            return .unregistered
        }
        if registration.content.isTerminal,
           registration.requestFirstResponder()
        {
            firstResponderOwnedSlotID = slotID
        }

        let desiredSurfaceID = explicitSurfaceID
            ?? registration.content.selectedSurfaceID
        var intents: [BackendOnlyProjectionAbsoluteIntent] = []
        intents.reserveCapacity(2)
        if desiredSurfaceID != registration.content.selectedSurfaceID {
            intents.append(.selectSurface(
                workspaceID: slotID.workspaceID,
                screenID: slotID.screenID,
                paneID: slotID.paneID,
                surfaceID: desiredSurfaceID
            ))
        }
        if authoritativeActiveSlotID != slotID {
            intents.append(.activatePane(
                workspaceID: slotID.workspaceID,
                screenID: slotID.screenID,
                paneID: slotID.paneID
            ))
        }
        guard !intents.isEmpty else { return .noChange }
        guard nextActionID != UInt64.max else {
            return .actionSequenceExhausted
        }

        let actionID = nextActionID
        nextActionID += 1
        newestRequestedActionID = actionID
        let action = BackendOnlyFocusAction(
            actionID: actionID,
            targetSlotID: slotID,
            desiredSurfaceID: desiredSurfaceID,
            intents: intents
        )
        let receipt = await submitAction(action)
        return apply(receipt: receipt, for: action)
    }

    private func apply(
        receipt: BackendOnlyFocusActionReceipt,
        for action: BackendOnlyFocusAction
    ) -> BackendOnlyFocusPointerResult {
        guard action.actionID == newestRequestedActionID,
              receipt.actionID == action.actionID
        else {
            return .ignoredStaleReceipt
        }
        guard receipt.outcome == .applied else {
            reconcileProgrammaticFocus()
            return .rejected
        }
        guard receipt.activeSlotID == action.targetSlotID,
              receipt.activeSlotID.logicalPresentationID
              == receipt.fence.logicalPresentationID,
              receipt.selectedSurfaceID == action.desiredSurfaceID
        else {
            return .ignoredStaleReceipt
        }

        let fenceOrder: AuthorityFenceOrder
        if let authorityFence {
            guard let order = compare(receipt.fence, with: authorityFence) else {
                return .ignoredStaleReceipt
            }
            fenceOrder = order
        } else {
            guard Self.isValid(receipt.fence) else {
                return .ignoredStaleReceipt
            }
            fenceOrder = .newer
        }
        guard fenceOrder == .newer else { return .ignoredStaleReceipt }

        authorityFence = receipt.fence
        authoritativeActiveSlotID = receipt.activeSlotID
        if var registration = registrations[receipt.activeSlotID] {
            registration.content = registration.content.selecting(
                receipt.selectedSurfaceID
            )
            registrations[receipt.activeSlotID] = registration
        }
        if firstResponderOwnedSlotID != receipt.activeSlotID {
            firstResponderOwnedSlotID = nil
        }
        reconcileProgrammaticFocus()
        return .applied
    }

    private func compare(
        _ incoming: BackendOnlyProjectionRuntimeFence,
        with current: BackendOnlyProjectionRuntimeFence
    ) -> AuthorityFenceOrder? {
        guard backendOnlyFocusFenceIsValid(incoming) else { return nil }
        if incoming.connectionGeneration < current.connectionGeneration {
            return .older
        }
        if incoming.connectionGeneration > current.connectionGeneration {
            return .newer
        }
        guard incoming.authority == current.authority,
              incoming.logicalPresentationID == current.logicalPresentationID
        else {
            return nil
        }
        guard incoming.topologyRevision >= current.topologyRevision,
              incoming.projectionGeneration >= current.projectionGeneration
        else {
            return .older
        }
        if incoming.topologyRevision == current.topologyRevision,
           incoming.projectionGeneration == current.projectionGeneration
        {
            return .same
        }
        return .newer
    }

    private func reconcileProgrammaticFocus() {
        guard isWindowKey,
              let activeSlotID = authoritativeActiveSlotID,
              let registration = registrations[activeSlotID],
              registration.content.isTerminal
        else {
            firstResponderOwnedSlotID = nil
            return
        }
        guard firstResponderOwnedSlotID != activeSlotID else { return }
        if registration.requestFirstResponder() {
            firstResponderOwnedSlotID = activeSlotID
        } else {
            firstResponderOwnedSlotID = nil
        }
    }
}

private func backendOnlyFocusFenceIsValid(
    _ fence: BackendOnlyProjectionRuntimeFence
) -> Bool {
    fence.connectionGeneration > 0
        && fence.topologyRevision > 0
        && fence.projectionGeneration > 0
        && !backendOnlyFocusIdentifierIsNil(fence.logicalPresentationID)
        && !backendOnlyFocusIdentifierIsNil(fence.authority.daemonInstanceID.rawValue)
        && !backendOnlyFocusIdentifierIsNil(fence.authority.sessionID.rawValue)
}

private func backendOnlyFocusIdentifierIsNil(_ identifier: UUID) -> Bool {
    identifier == UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ))
}
