public import Foundation

/// The host's login policy for the actual frame receiving agent code. The driver resolves and
/// probes that frame; the composition root supplies the shared, profile-scoped login guard.
@MainActor
public struct BrowserFrameCodePolicy {
    let admit: (String, [String]) async -> String?
    let ran: (String, [String]) async -> Void

    /// `admit` atomically checks and marks the selected frame's origins; nil admits the call.
    /// An origin set containing `null` must exclude fills across the entire profile: opaque and
    /// inherited frames can switch documents without changing their location-origin pin.
    /// `ran` also marks its final origins. Neither callback receives agent source or credentials.
    public init(admit: @escaping (String, [String]) async -> String?,
                ran: @escaping (String, [String]) async -> Void) {
        self.admit = admit
        self.ran = ran
    }
}
