public import Foundation

/// The outcome of resolving a terminal-aliasing identifier from a mobile RPC's
/// params.
///
/// The mobile data plane accepts a terminal under any of three interchangeable
/// alias keys (`surface_id`, `terminal_id`, `tab_id`). Resolving them is a pure
/// classification: no alias present, exactly one well-formed UUID, a malformed
/// alias value, or two aliases that disagree. This enum is the single value-typed
/// result of that classification so the resolution can be validated and tested
/// without a live connection.
///
/// The resolution itself stays on the Mac (it reads app-side v2 param helpers);
/// only this result shape lives here in the shared mobile value-type domain.
public enum MobileTerminalAliasUUID: Sendable {
    /// No terminal alias key was present in the params.
    case missing
    /// Exactly one well-formed terminal alias UUID was resolved.
    case value(UUID)
    /// A terminal alias key was present but its value was not a valid UUID.
    case invalid
    /// Two or more alias keys were present with conflicting UUID values.
    case conflict
}
