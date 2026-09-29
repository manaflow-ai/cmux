import Foundation

/// The structured error contract returned by the Cloud VM control plane.
public struct CloudVMHTTPError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String

    public init(status: Int, body: String) {
        self.status = status
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        self.code = (object?["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http_\(status)"
    }

    /// Whether the server conclusively says that this machine no longer exists.
    /// Other 404s and all transport/provider failures remain reconnectable.
    public var isMachineNotFound: Bool {
        status == 404 && code == "vm_not_found"
    }
}
