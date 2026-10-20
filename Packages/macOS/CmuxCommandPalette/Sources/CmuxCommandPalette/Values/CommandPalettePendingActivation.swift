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
