public import Foundation

/// A local `ssh -O exit` request for a cmux-owned native SSH master.
public struct NativeSSHControlMasterCleanupRequest: Sendable {
    /// Arguments passed to `/usr/bin/ssh`.
    public let arguments: [String]

    /// Environment passed to the cleanup process, including an injected agent socket when present.
    public let environment: [String: String]?

    /// Creates a cleanup process request.
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed to `/usr/bin/ssh`.
    ///   - environment: Optional process environment.
    public init(arguments: [String], environment: [String: String]?) {
        self.arguments = arguments
        self.environment = environment
    }
}
