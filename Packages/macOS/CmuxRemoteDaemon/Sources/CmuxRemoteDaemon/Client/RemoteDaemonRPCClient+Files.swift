public import Foundation

extension RemoteDaemonRPCClient {
    /// Maximum decoded payload accepted from `file.read`, matching the daemon.
    public static let maximumRemoteFileReadBytes = 1024 * 1024

    /// Whether the connected daemon advertised `capability` in its hello.
    ///
    /// - Parameter capability: Capability to test against the handshake snapshot.
    /// - Returns: `true` when the daemon advertised the capability.
    public func supports(_ capability: RemoteDaemonCapability) -> Bool {
        stateQueue.sync {
            advertisedCapabilities.contains(capability.rawValue)
        }
    }

    /// Returns metadata for an absolute path through `fs.stat`.
    ///
    /// - Parameters:
    ///   - path: Absolute path on the remote host.
    ///   - timeout: Maximum time to wait for the daemon response.
    /// - Returns: The remote filesystem metadata snapshot.
    /// - Throws: An RPC, capability, timeout, or wire-decoding error.
    public func statFile(path: String, timeout: TimeInterval = 8.0) throws -> RemoteDaemonFileStat {
        try requireCapability(.fsStat)
        let result = try call(
            method: RemoteDaemonCapability.fsStat.rawValue,
            params: ["path": path],
            timeout: max(0, timeout)
        )
        return try Self.decodeFileStatResult(result)
    }

    /// Validates the daemon's `fs.stat` result before constructing metadata.
    static func decodeFileStatResult(_ result: [String: Any]) throws -> RemoteDaemonFileStat {
        guard let exists = result["exists"] as? Bool else {
            throw Self.invalidFileStatMetadataError()
        }
        guard exists else {
            return .missing
        }
        guard let rawKind = result["type"] as? String,
              let kind = RemoteDaemonFileStat.Kind(rawValue: rawKind),
              let size = (result["size"] as? NSNumber)?.int64Value,
              size >= 0 else {
            throw Self.invalidFileStatMetadataError()
        }
        return .existing(kind: kind, size: size)
    }

    /// Reads one regular file through the daemon's one-megabyte-bounded
    /// `file.read` RPC.
    ///
    /// - Parameters:
    ///   - path: Absolute regular-file path on the remote host.
    ///   - timeout: Maximum time to wait for the daemon response.
    /// - Returns: At most ``maximumRemoteFileReadBytes`` decoded bytes.
    /// - Throws: An RPC, capability, timeout, bounds, or wire-decoding error.
    public func readFile(path: String, timeout: TimeInterval = 8.0) throws -> Data {
        try requireCapability(.fileRead)
        let result = try call(
            method: RemoteDaemonCapability.fileRead.rawValue,
            params: ["path": path],
            timeout: max(0, timeout)
        )
        guard let encoded = result["data_base64"] as? String,
              let data = Data(base64Encoded: encoded),
              data.count <= Self.maximumRemoteFileReadBytes else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 36, userInfo: [
                NSLocalizedDescriptionKey: "file.read returned invalid data",
            ])
        }
        return data
    }

    private func requireCapability(_ capability: RemoteDaemonCapability) throws {
        guard supports(capability) else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 37, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon does not support \(capability.rawValue)",
            ])
        }
    }

    private static func invalidFileStatMetadataError() -> NSError {
        NSError(domain: "cmux.remote.daemon.rpc", code: 35, userInfo: [
            NSLocalizedDescriptionKey: "fs.stat returned invalid metadata",
        ])
    }
}
