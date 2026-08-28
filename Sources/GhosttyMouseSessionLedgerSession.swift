import Foundation

extension GhosttyMouseSessionLedger {
    /// An opaque generation token for one button press.
    struct Session: Hashable, Sendable {
        let button: Button
        let generation: UInt64
        let surface: SurfaceIdentity
    }
}
