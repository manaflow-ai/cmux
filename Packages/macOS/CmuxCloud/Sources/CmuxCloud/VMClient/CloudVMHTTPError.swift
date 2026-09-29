import Foundation

/// The structured error contract returned by the Cloud VM control plane.
public struct CloudVMHTTPError: Error, Equatable, Sendable {
    /// The HTTP status returned by the Cloud VM control plane.
    public let status: Int
    /// The structured backend error code, or an HTTP fallback when the body is not JSON.
    public let code: String

    /// Creates a typed error from one Cloud VM response body.
    public init(status: Int, body: String) {
        self.status = status
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if let rawCode = object?["error"] as? String {
            let trimmedCode = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCode.isEmpty {
                self.code = trimmedCode
                return
            }
        }
        self.code = "http_\(status)"
    }

    /// Whether the server conclusively says that this machine no longer exists.
    /// Other 404s and all transport/provider failures remain reconnectable.
    public var isMachineNotFound: Bool {
        status == 404 && code == "vm_not_found"
    }
}
