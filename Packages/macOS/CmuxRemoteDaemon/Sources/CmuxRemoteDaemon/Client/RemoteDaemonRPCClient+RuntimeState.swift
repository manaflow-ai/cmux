internal import CoreFoundation
public import Foundation

extension RemoteDaemonRPCClient {
    /// Fetches the daemon's authoritative workspace snapshot.
    ///
    /// - Returns: The current document, or `nil` when no client has seeded the runtime.
    /// - Throws: A transport, protocol, or malformed-document error.
    public func getRuntimeState() throws -> RemoteRuntimeStateDocument? {
        let result = try call(method: "runtime.state.get", params: [:], timeout: 8.0)
        return try Self.decodeRuntimeStateDocument(result)
    }

    /// Replaces the daemon's authoritative workspace snapshot.
    ///
    /// Omitting `expectedRevision` uses last-writer-wins semantics. Supplying
    /// it makes the update conditional and surfaces `revision_conflict` when
    /// another view published first.
    ///
    /// - Parameters:
    ///   - schemaVersion: Client-owned schema version for `state`.
    ///   - state: Workspace snapshot encoded as a JSON object.
    ///   - expectedRevision: Optional daemon revision precondition.
    /// - Returns: The newly committed daemon document.
    /// - Throws: A transport, validation, conflict, or malformed-document error.
    public func putRuntimeState(
        schemaVersion: Int,
        state: Data,
        expectedRevision: UInt64? = nil
    ) throws -> RemoteRuntimeStateDocument {
        guard schemaVersion > 0 else {
            throw Self.runtimeStateError(code: 40, message: "runtime state schema version must be greater than zero")
        }
        let stateObject = try JSONSerialization.jsonObject(with: state, options: [])
        guard stateObject is [String: Any] else {
            throw Self.runtimeStateError(code: 41, message: "runtime state must be a JSON object")
        }
        var params: [String: Any] = [
            "schema_version": schemaVersion,
            "state": stateObject,
        ]
        if let expectedRevision {
            params["expected_revision"] = NSNumber(value: expectedRevision)
        }
        let result = try call(method: "runtime.state.put", params: params, timeout: 8.0)
        guard let document = try Self.decodeRuntimeStateDocument(result) else {
            throw Self.runtimeStateError(code: 42, message: "runtime.state.put returned no document")
        }
        return document
    }

    static func decodeRuntimeStateDocument(_ result: [String: Any]) throws -> RemoteRuntimeStateDocument? {
        guard let present = result["present"] as? Bool,
              let protocolVersion = Self.integer(result["protocol_version"]),
              let revision = Self.unsignedInteger(result["revision"]),
              let ptySessions = result["pty_sessions"] as? [Any],
              JSONSerialization.isValidJSONObject(ptySessions) else {
            throw Self.runtimeStateError(code: 44, message: "runtime state document is malformed")
        }
        guard protocolVersion == RemoteRuntimeStateDocument.protocolVersion else {
            throw Self.runtimeStateError(code: 43, message: "runtime state protocol version is unsupported")
        }
        guard present else {
            guard revision == 0 else {
                throw Self.runtimeStateError(code: 44, message: "runtime state document is malformed")
            }
            return nil
        }
        guard let schemaVersion = Self.integer(result["schema_version"]), schemaVersion > 0,
              revision > 0,
              let updatedAt = Self.signedInteger(result["updated_at_unix_ms"]), updatedAt > 0,
              let stateObject = result["state"] as? [String: Any] else {
            throw Self.runtimeStateError(code: 44, message: "runtime state document is malformed")
        }
        guard JSONSerialization.isValidJSONObject(stateObject) else {
            throw Self.runtimeStateError(code: 45, message: "runtime state document contains invalid JSON")
        }
        return try RemoteRuntimeStateDocument(
            schemaVersion: schemaVersion,
            revision: revision,
            updatedAtUnixMilliseconds: updatedAt,
            state: JSONSerialization.data(withJSONObject: stateObject, options: [.sortedKeys]),
            ptySessions: JSONSerialization.data(withJSONObject: ptySessions, options: [.sortedKeys])
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.intValue
        return NSNumber(value: result) == number ? result : nil
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0 else { return nil }
        let result = number.uint64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func runtimeStateError(code: Int, message: String) -> NSError {
        NSError(domain: "cmux.remote.daemon.runtime-state", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
