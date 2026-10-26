public import Foundation
public import LocalAuthentication

extension LAContext {
    /// Whether the policy can be evaluated now, like `canEvaluatePolicy(_:error:)`, as a checked blocking
    /// call (``blockingCall(_:fileID:line:_:)``, kind ``BlockingKind/systemCall``): it waits for coreauthd's
    /// reply (about 0.5 s in a macOS 26 VM). `evaluatePolicy(_:localizedReason:reply:)` replies on a callback
    /// and needs no seam.
    ///
    /// - Parameters:
    ///   - policy: The policy.
    ///   - error: Receives why it cannot, or nil.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: Whether the policy can be evaluated.
    @inlinable
    public func blockingCanEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer = nil,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.systemCall, fileID: fileID, line: line) { canEvaluatePolicy(policy, error: error) }
    }
}
