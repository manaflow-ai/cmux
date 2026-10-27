public import Foundation
public import LocalAuthentication

extension LAContext {
    /// ``blockingCanEvaluatePolicy(_:error:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingCanEvaluatePolicy(_ policy: LAPolicy, _ permit: borrowing BlockingPermit, error: NSErrorPointer = nil,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.systemCall, permit, fileID: fileID, line: line) { canEvaluatePolicy(policy, error: error) }
    }
}
