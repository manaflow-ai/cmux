import Foundation

/// The result of resolving a terminal name to its device number.
enum PortTerminalDeviceLookup: Sendable, Equatable {
    /// The terminal exists; processes attached to it report this device in
    /// `proc_bsdinfo.e_tdev`.
    case device(UInt32)
    /// No terminal by that name exists, so no process can be attached to it.
    /// A freed pty is authoritative emptiness, not missing evidence.
    case absent
    /// The terminal could not be inspected. Its processes are unknown, so a
    /// scan that includes it is incomplete.
    case unreadable
}
