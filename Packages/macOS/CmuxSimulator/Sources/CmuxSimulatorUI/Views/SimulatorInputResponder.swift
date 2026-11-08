import Foundation

/// Identifies AppKit responders owned by one native Simulator pane.
@MainActor
public protocol SimulatorInputResponder: AnyObject {
    /// The owning pane coordinator identity used for focus routing.
    var simulatorOwnerID: ObjectIdentifier? { get }
}
