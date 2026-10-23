import Foundation

/// A create pressed on a stand-in pane that has no daemon pane and no anchor left to fall back
/// to (``DaemonStore/daemonTarget(for:)``): nothing is sent, since the daemon would refuse a
/// stand-in's handle, and the create is refused (its stand-in leaves exactly).
public struct CreateTargetGone: Error, CustomStringConvertible {
    /// The stand-in handle the create named.
    public let pane: PaneID

    public var description: String { "the pane \(pane.rawValue) the create was pressed on is gone" }
}
