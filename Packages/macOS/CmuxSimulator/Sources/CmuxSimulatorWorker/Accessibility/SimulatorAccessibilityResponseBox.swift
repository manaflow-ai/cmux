import Foundation

/// Holds the private XPC response until the synchronous translator bridge resumes.
///
/// Safety: the completion queue is the only writer, and `DispatchGroup.wait`
/// establishes a happens-before relationship before the worker reads `value`.
final class SimulatorAccessibilityResponseBox: @unchecked Sendable {
    var value: AnyObject?
}
