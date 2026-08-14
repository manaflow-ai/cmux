import Foundation

/// Explicitly transfers a private CoreSimulator object into the worker's
/// accessibility actor.
///
/// Safety: the object never leaves the isolated worker process, and only the
/// receiving `SimulatorAccessibilityExecutor` dereferences it.
struct SimulatorAccessibilityDevice: @unchecked Sendable {
    let object: NSObject

    init(_ object: NSObject) {
        self.object = object
    }
}
