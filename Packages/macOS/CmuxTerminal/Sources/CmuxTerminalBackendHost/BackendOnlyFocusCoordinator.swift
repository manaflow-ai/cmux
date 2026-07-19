internal import CmuxTerminalBackend
internal import Foundation

/// Visible pane materialization relevant to terminal first-responder policy.
nonisolated enum BackendOnlyFocusSlotContent: Equatable, Sendable {
    case terminal(selectedSurfaceID: SurfaceID)
    case browserPlaceholder(selectedSurfaceID: SurfaceID)
    case unsupportedPlaceholder(selectedSurfaceID: SurfaceID)

    var selectedSurfaceID: SurfaceID {
        switch self {
        case .terminal(let selectedSurfaceID),
             .browserPlaceholder(let selectedSurfaceID),
             .unsupportedPlaceholder(let selectedSurfaceID):
            selectedSurfaceID
        }
    }

    var isTerminal: Bool {
        if case .terminal = self { true } else { false }
    }

    func selecting(_ surfaceID: SurfaceID) -> BackendOnlyFocusSlotContent {
        switch self {
        case .terminal:
            .terminal(selectedSurfaceID: surfaceID)
        case .browserPlaceholder:
            .browserPlaceholder(selectedSurfaceID: surfaceID)
        case .unsupportedPlaceholder:
            .unsupportedPlaceholder(selectedSurfaceID: surfaceID)
        }
    }
}

/// One pointer gesture expressed as a single ordered daemon action.
nonisolated struct BackendOnlyFocusAction: Equatable, Sendable {
    let actionID: UInt64
    let targetSlotID: BackendOnlyProjectionSlotID
    let desiredSurfaceID: SurfaceID
    let intents: [BackendOnlyProjectionAbsoluteIntent]
}

nonisolated enum BackendOnlyFocusActionReceiptOutcome: Equatable, Sendable {
    case applied
    case rejected
}

/// Authoritative daemon result for one exact focus action.
nonisolated struct BackendOnlyFocusActionReceipt: Equatable, Sendable {
    let actionID: UInt64
    let authorityRevision: UInt64
    let outcome: BackendOnlyFocusActionReceiptOutcome
    let activeSlotID: BackendOnlyProjectionSlotID
    let selectedSurfaceID: SurfaceID
}

nonisolated enum BackendOnlyFocusPointerResult: Equatable, Sendable {
    case unregistered
    case noChange
    case applied
    case rejected
    case ignoredStaleReceipt
    case actionSequenceExhausted
}

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

    private struct Registration {
        var content: BackendOnlyFocusSlotContent
        let requestFirstResponder: @MainActor () -> Bool
    }

    private var registrations: [BackendOnlyProjectionSlotID: Registration] = [:]
    private let submitAction: BackendOnlyFocusActionSubmitter
    private var nextActionID: UInt64 = 1
    private var newestRequestedActionID: UInt64 = 0

    private(set) var authoritativeActiveSlotID: BackendOnlyProjectionSlotID?
    private(set) var authorityRevision: UInt64 = 0
    private(set) var firstResponderOwnedSlotID: BackendOnlyProjectionSlotID?
    private(set) var isWindowKey = false

    var registeredSlotCount: Int { registrations.count }

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
                || registrations.count < Self.maximumRegisteredSlotCount else {
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
        authorityRevision incomingRevision: UInt64
    ) -> Bool {
        guard incomingRevision > authorityRevision else { return false }
        authorityRevision = incomingRevision
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
              receipt.actionID == action.actionID else {
            return .ignoredStaleReceipt
        }
        guard receipt.outcome == .applied else {
            reconcileProgrammaticFocus()
            return .rejected
        }
        guard receipt.authorityRevision > authorityRevision,
              receipt.activeSlotID == action.targetSlotID,
              receipt.selectedSurfaceID == action.desiredSurfaceID else {
            return .ignoredStaleReceipt
        }

        authorityRevision = receipt.authorityRevision
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

    private func reconcileProgrammaticFocus() {
        guard isWindowKey,
              let activeSlotID = authoritativeActiveSlotID,
              let registration = registrations[activeSlotID],
              registration.content.isTerminal else {
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
