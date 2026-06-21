import Foundation

/// A queued palette activation (Return pressed) waiting for the in-flight
/// search whose `requestID` it captured to resolve.
public enum CommandPalettePendingActivation: Equatable {
    /// Activate whatever ends up selected; fall back to `fallbackSelectedIndex`
    /// or `preferredCommandID` when the results changed.
    case selected(requestID: UInt64, fallbackSelectedIndex: Int, preferredCommandID: String?)
    /// Activate the specific command `commandID`.
    case command(requestID: UInt64, commandID: String)
}

extension CommandPalettePendingActivation {
    /// The search `requestID` this activation captured when it was queued.
    public var requestID: UInt64 {
        switch self {
        case .selected(let requestID, _, _):
            return requestID
        case .command(let requestID, _):
            return requestID
        }
    }

    /// Returns a copy of this activation re-pinned to a new search `requestID`,
    /// preserving the activation kind and its captured fallbacks.
    public func rebased(toRequestID requestID: UInt64) -> CommandPalettePendingActivation {
        switch self {
        case .selected(_, let fallbackSelectedIndex, let preferredCommandID):
            return .selected(
                requestID: requestID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                preferredCommandID: preferredCommandID
            )
        case .command(_, let commandID):
            return .command(requestID: requestID, commandID: commandID)
        }
    }

    /// Resolves this activation against the `resultIDs` available for `requestID`,
    /// or `nil` when this activation does not match `requestID` (or its command is
    /// no longer present in the results).
    public func resolved(
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPaletteResolvedActivation? {
        switch self {
        case .selected(let activationRequestID, let fallbackSelectedIndex, let preferredCommandID):
            guard activationRequestID == requestID else { return nil }
            let resolvedIndex = Self.resolvedSelectionIndex(
                preferredCommandID: preferredCommandID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                resultIDs: resultIDs
            )
            return .selected(index: resolvedIndex)
        case .command(let activationRequestID, let commandID):
            guard activationRequestID == requestID, resultIDs.contains(commandID) else { return nil }
            return .command(commandID: commandID)
        }
    }

    /// The selection index to use given an optional anchored `preferredCommandID`,
    /// clamped to the bounds of `resultIDs`. When the anchor is present in the
    /// results it wins; otherwise `fallbackSelectedIndex` is clamped into range.
    public static func resolvedSelectionIndex(
        preferredCommandID: String?,
        fallbackSelectedIndex: Int,
        resultIDs: [String]
    ) -> Int {
        guard !resultIDs.isEmpty else { return 0 }
        if let preferredCommandID,
           let anchoredIndex = resultIDs.firstIndex(of: preferredCommandID) {
            return anchoredIndex
        }
        return min(max(fallbackSelectedIndex, 0), resultIDs.count - 1)
    }
}

extension Optional where Wrapped == CommandPalettePendingActivation {
    /// Resolves this (optional) pending activation against the current
    /// `resultIDs` for `requestID`, also reporting whether the pending activation
    /// should be cleared. A `nil` activation resolves to nothing and is not
    /// cleared; an activation whose captured `requestID` matches is cleared.
    public func resolution(
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPalettePendingActivationResolutionResult {
        CommandPalettePendingActivationResolutionResult(
            resolvedActivation: self?.resolved(requestID: requestID, resultIDs: resultIDs),
            shouldClearPendingActivation: self?.requestID == requestID
        )
    }
}
