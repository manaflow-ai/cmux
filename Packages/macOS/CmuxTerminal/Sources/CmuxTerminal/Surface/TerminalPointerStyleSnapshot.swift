public import Foundation

/// A complete pointer value and the ordering/identity of the callbacks it includes.
public struct TerminalPointerStyleSnapshot: Sendable {
    /// Semantic pointer state; contains no AppKit objects.
    public internal(set) var intent = TerminalPointerIntentState()
    /// Monotonic version used to reject delayed UI deliveries.
    public internal(set) var revision: UInt64 = 0
    /// Native generation captured in Ghostty callback userdata.
    public internal(set) var runtimeGeneration: UInt64 = 0
    /// Logical terminal surface that owns the native runtime.
    public internal(set) var surfaceId: UUID?
    /// Focus epoch, advanced synchronously before post-focus callbacks arrive.
    public internal(set) var focusGeneration: UInt64 = 0
}
