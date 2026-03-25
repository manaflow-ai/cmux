struct GhosttyScrollbar: Equatable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(total: Int, offset: Int, len: Int) {
        self.total = UInt64(max(0, total))
        self.offset = UInt64(max(0, offset))
        self.len = UInt64(max(0, len))
    }

    var totalRows: Int { Int(min(total, UInt64(Int.max))) }
    var offsetRows: Int { Int(min(offset, UInt64(Int.max))) }
    var visibleRows: Int { Int(min(len, UInt64(Int.max))) }
    var maxTopVisibleRow: Int { max(0, totalRows - visibleRows) }
    var incomingTopVisibleRow: Int {
        max(0, min(maxTopVisibleRow, maxTopVisibleRow - offsetRows))
    }
}

struct GhosttyScrollViewportSyncPlan: Equatable {
    let targetTopVisibleRow: Int
    let targetRowFromBottom: Int
    let storedTopVisibleRow: Int?
}

enum GhosttyViewportChangeSource {
    case userInteraction
    case internalCorrection
}

enum GhosttyViewportInteraction {
    case scrollWheel
    case bindingAction(action: String, source: GhosttyViewportChangeSource)
}

enum GhosttyTerminalFocusRequestSource {
    case automaticFirstResponderRestore
    case automaticEnsureFocus
    case explicitUserAction
}

enum GhosttyFirstResponderAcquisitionSource {
    case automaticWindowActivation
    case directSurfaceInteraction
}

struct GhosttyScrollCorrectionDispatchState: Equatable {
    let lastSentRow: Int?
    let pendingAnchorCorrectionRow: Int?
}

struct GhosttyExplicitViewportChangeConsumption: Equatable {
    let isExplicitViewportChange: Bool
    let remainingPendingExplicitViewportChange: Bool
}

struct GhosttyExplicitFocusRestoreConsumption: Equatable {
    let focusRequestSource: GhosttyTerminalFocusRequestSource
    let remainingPendingExplicitFocusRestoreAfterKeyLoss: Bool
    let remainingHasLostKeySinceExplicitFocusRestoreRequest: Bool
}

struct GhosttyAutomaticTerminalFocusRestorePlan: Equatable {
    let shouldRestoreFirstResponder: Bool
    let shouldReassertTerminalSurfaceFocus: Bool
}

func ghosttyScrollViewportSyncPlan(
    scrollbar: GhosttyScrollbar,
    storedTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> GhosttyScrollViewportSyncPlan {
    guard scrollbar.visibleRows > 0 else {
        return GhosttyScrollViewportSyncPlan(
            targetTopVisibleRow: 0,
            targetRowFromBottom: 0,
            storedTopVisibleRow: nil
        )
    }

    let clampedStoredTopVisibleRow = storedTopVisibleRow.map {
        max(0, min($0, scrollbar.maxTopVisibleRow))
    }
    let targetTopVisibleRow: Int
    if isExplicitViewportChange {
        targetTopVisibleRow = scrollbar.incomingTopVisibleRow
    } else if let clampedStoredTopVisibleRow {
        targetTopVisibleRow = clampedStoredTopVisibleRow
    } else {
        targetTopVisibleRow = scrollbar.incomingTopVisibleRow
    }
    let targetRowFromBottom = max(0, scrollbar.maxTopVisibleRow - targetTopVisibleRow)
    let resultingStoredTopVisibleRow: Int?
    if isExplicitViewportChange {
        resultingStoredTopVisibleRow = targetRowFromBottom > 0 ? targetTopVisibleRow : nil
    } else if let clampedStoredTopVisibleRow {
        resultingStoredTopVisibleRow = clampedStoredTopVisibleRow
    } else {
        resultingStoredTopVisibleRow = targetRowFromBottom > 0 ? targetTopVisibleRow : nil
    }
    return GhosttyScrollViewportSyncPlan(
        targetTopVisibleRow: targetTopVisibleRow,
        targetRowFromBottom: targetRowFromBottom,
        storedTopVisibleRow: resultingStoredTopVisibleRow
    )
}

func ghosttyBindingActionMutatesViewport(_ action: String) -> Bool {
    action.hasPrefix("scroll_") ||
        action.hasPrefix("jump_to_prompt:") ||
        action == "search:next" ||
        action == "search:previous" ||
        action == "navigate_search:next" ||
        action == "navigate_search:previous"
}

func ghosttyShouldMarkExplicitViewportChange(
    action: String,
    source: GhosttyViewportChangeSource
) -> Bool {
    guard source == .userInteraction else { return false }
    return ghosttyBindingActionMutatesViewport(action)
}

func ghosttyShouldBeginExplicitViewportChange(
    for interaction: GhosttyViewportInteraction
) -> Bool {
    switch interaction {
    case .scrollWheel:
        return true
    case let .bindingAction(action, source):
        return ghosttyShouldMarkExplicitViewportChange(action: action, source: source)
    }
}

func ghosttyConsumeExplicitViewportChange(
    pendingExplicitViewportChange: Bool,
    baselineScrollbar: GhosttyScrollbar?,
    incomingScrollbar: GhosttyScrollbar
) -> GhosttyExplicitViewportChangeConsumption {
    guard pendingExplicitViewportChange else {
        return GhosttyExplicitViewportChangeConsumption(
            isExplicitViewportChange: false,
            remainingPendingExplicitViewportChange: false
        )
    }
    guard let baselineScrollbar else {
        return GhosttyExplicitViewportChangeConsumption(
            isExplicitViewportChange: true,
            remainingPendingExplicitViewportChange: false
        )
    }
    if incomingScrollbar.incomingTopVisibleRow != baselineScrollbar.incomingTopVisibleRow {
        return GhosttyExplicitViewportChangeConsumption(
            isExplicitViewportChange: true,
            remainingPendingExplicitViewportChange: false
        )
    }
    if incomingScrollbar == baselineScrollbar {
        return GhosttyExplicitViewportChangeConsumption(
            isExplicitViewportChange: false,
            remainingPendingExplicitViewportChange: true
        )
    }
    return GhosttyExplicitViewportChangeConsumption(
        isExplicitViewportChange: false,
        remainingPendingExplicitViewportChange: false
    )
}

func ghosttyConsumeExplicitFocusRestoreAfterKeyLoss(
    pendingExplicitFocusRestoreAfterKeyLoss: Bool,
    hasLostKeySinceExplicitFocusRestoreRequest: Bool,
    baseFocusRequestSource: GhosttyTerminalFocusRequestSource
) -> GhosttyExplicitFocusRestoreConsumption {
    guard pendingExplicitFocusRestoreAfterKeyLoss else {
        return GhosttyExplicitFocusRestoreConsumption(
            focusRequestSource: baseFocusRequestSource,
            remainingPendingExplicitFocusRestoreAfterKeyLoss: false,
            remainingHasLostKeySinceExplicitFocusRestoreRequest: false
        )
    }
    guard hasLostKeySinceExplicitFocusRestoreRequest else {
        return GhosttyExplicitFocusRestoreConsumption(
            focusRequestSource: baseFocusRequestSource,
            remainingPendingExplicitFocusRestoreAfterKeyLoss: true,
            remainingHasLostKeySinceExplicitFocusRestoreRequest: false
        )
    }

    return GhosttyExplicitFocusRestoreConsumption(
        focusRequestSource: .explicitUserAction,
        remainingPendingExplicitFocusRestoreAfterKeyLoss: false,
        remainingHasLostKeySinceExplicitFocusRestoreRequest: false
    )
}

func ghosttyResolvedStoredTopVisibleRow(
    storedTopVisibleRow: Int?,
    currentViewportTopVisibleRow: Int?,
    currentViewportRowFromBottom: Int?,
    isExplicitViewportChange: Bool,
    hasPendingAnchorCorrection: Bool
) -> Int? {
    guard !isExplicitViewportChange, !hasPendingAnchorCorrection else {
        return storedTopVisibleRow
    }
    guard storedTopVisibleRow == nil else {
        return storedTopVisibleRow
    }
    guard let currentViewportTopVisibleRow,
          let currentViewportRowFromBottom,
          currentViewportTopVisibleRow > 0 || currentViewportRowFromBottom > 0 else {
        return storedTopVisibleRow
    }
    return currentViewportTopVisibleRow
}

func ghosttyPassiveScrollViewportSyncPlan(
    scrollbar: GhosttyScrollbar,
    storedTopVisibleRow: Int?,
    currentViewportTopVisibleRow: Int?,
    currentViewportRowFromBottom: Int?,
    hasPendingAnchorCorrection: Bool
) -> GhosttyScrollViewportSyncPlan {
    let resolvedStoredTopVisibleRow = ghosttyResolvedStoredTopVisibleRow(
        storedTopVisibleRow: storedTopVisibleRow,
        currentViewportTopVisibleRow: currentViewportTopVisibleRow,
        currentViewportRowFromBottom: currentViewportRowFromBottom,
        isExplicitViewportChange: false,
        hasPendingAnchorCorrection: hasPendingAnchorCorrection
    )
    return ghosttyScrollViewportSyncPlan(
        scrollbar: scrollbar,
        storedTopVisibleRow: resolvedStoredTopVisibleRow,
        isExplicitViewportChange: false
    )
}

func ghosttyBaselineScrollbarForIncomingUpdate(
    lastAcceptedScrollbar: GhosttyScrollbar?,
    currentSurfaceScrollbar: GhosttyScrollbar?
) -> GhosttyScrollbar? {
    lastAcceptedScrollbar ?? currentSurfaceScrollbar
}

func ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
    previousScrollbar: GhosttyScrollbar?,
    incomingScrollbar: GhosttyScrollbar,
    resolvedStoredTopVisibleRow: Int?,
    resultingStoredTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> Bool {
    guard !isExplicitViewportChange else {
        return false
    }
    guard let previousScrollbar else {
        return false
    }
    guard incomingScrollbar.totalRows < previousScrollbar.totalRows else {
        return false
    }
    return resolvedStoredTopVisibleRow != nil || resultingStoredTopVisibleRow == nil
}

func ghosttyAutomaticTerminalFocusRestorePlan(
    storedTopVisibleRow: Int?,
    focusRequestSource: GhosttyTerminalFocusRequestSource
) -> GhosttyAutomaticTerminalFocusRestorePlan {
    switch focusRequestSource {
    case .automaticFirstResponderRestore, .automaticEnsureFocus:
        return GhosttyAutomaticTerminalFocusRestorePlan(
            shouldRestoreFirstResponder: true,
            shouldReassertTerminalSurfaceFocus: storedTopVisibleRow == nil
        )
    case .explicitUserAction:
        return GhosttyAutomaticTerminalFocusRestorePlan(
            shouldRestoreFirstResponder: true,
            shouldReassertTerminalSurfaceFocus: true
        )
    }
}

func ghosttyShouldAutomaticallyReassertTerminalFocus(
    storedTopVisibleRow: Int?,
    focusRequestSource: GhosttyTerminalFocusRequestSource
) -> Bool {
    ghosttyAutomaticTerminalFocusRestorePlan(
        storedTopVisibleRow: storedTopVisibleRow,
        focusRequestSource: focusRequestSource
    ).shouldReassertTerminalSurfaceFocus
}

func ghosttyShouldRestoreAutomaticTerminalFocus(storedTopVisibleRow: Int?) -> Bool {
    ghosttyShouldAutomaticallyReassertTerminalFocus(
        storedTopVisibleRow: storedTopVisibleRow,
        focusRequestSource: .automaticFirstResponderRestore
    )
}

func ghosttyShouldApplyTerminalSurfaceFocusOnFirstResponderAcquisition(
    storedTopVisibleRow: Int?,
    acquisitionSource: GhosttyFirstResponderAcquisitionSource
) -> Bool {
    switch acquisitionSource {
    case .automaticWindowActivation:
        return storedTopVisibleRow == nil
    case .directSurfaceInteraction:
        return true
    }
}

func ghosttyScrollCorrectionDispatchState(
    previousLastSentRow: Int?,
    previousPendingAnchorCorrectionRow: Int?,
    targetRowFromBottom: Int,
    dispatchSucceeded: Bool
) -> GhosttyScrollCorrectionDispatchState {
    guard dispatchSucceeded else {
        return GhosttyScrollCorrectionDispatchState(
            lastSentRow: previousLastSentRow,
            pendingAnchorCorrectionRow: previousPendingAnchorCorrectionRow
        )
    }

    return GhosttyScrollCorrectionDispatchState(
        lastSentRow: targetRowFromBottom,
        pendingAnchorCorrectionRow: targetRowFromBottom
    )
}
