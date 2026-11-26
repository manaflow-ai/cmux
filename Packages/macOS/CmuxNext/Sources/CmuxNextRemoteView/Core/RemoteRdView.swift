import CCmuxRdFFI
import Foundation

/// The viewer rules Rust answers (crate cmux-rd-ffi, `cmux_rd_ffi::view`, through
/// `cmux_rd_view_call`): a request is a JSON object `{"op": "...", ...}` and every op is pure,
/// state in and next state out. One handle per call: the ops keep no state between calls and
/// the handle is not thread-safe, so no handle is shared.
nonisolated enum RemoteRdView {
    /// Runs one request; nil when the library refused it (not a request, or an op this library
    /// does not have).
    static func call(_ request: [String: Any]) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let view = cmux_rd_view_new() else { return nil }
        defer { cmux_rd_view_free(view) }
        var out: UnsafePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { raw in
            cmux_rd_view_call(view, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &out, &length)
        }
        guard status == CMUX_RD_OK, let out else { return nil }
        let reply = Data(bytes: out, count: length)
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    /// A Rust `SessionEnd` (`{"kind": ...}`).
    static func sessionEnd(_ value: Any?) -> RemoteSessionEnd? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "disconnectedBy": return .disconnectedBy(name: object["name"] as? String ?? "")
        case "hostStoppedSharing": return .hostStoppedSharing
        case "hostFailed": return .hostFailed(reason: object["reason"] as? String ?? "")
        case "stoppedByViewer": return .stoppedByViewer
        case "connectionLost": return .connectionLost
        case "consentDenied": return .consentDenied
        case "signInRequired": return .signInRequired(rejected: object["rejected"] as? Bool ?? false)
        default: return nil
        }
    }
}
