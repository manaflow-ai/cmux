import CCmuxSettingsFFI
import Foundation

/// cmux-config's app ops (`cmux_settings_call`, cmux-tui `cmux_config::app_ops`): one JSON
/// object in, one out; nil when the op did not run.
enum CmuxSettingsFFI {
    static func call(_ op: String, _ request: [String: Any]) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxSettingsBytes(ptr: nil, len: 0)
        let code: Int32 = body.withUnsafeBytes { raw in
            op.withCString { name in cmux_settings_call(name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out) }
        }
        defer { cmux_settings_bytes_free(out) }
        guard code == CMUX_SETTINGS_OK, let bytes = out.ptr, out.len > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: out.len))) as? [String: Any]
    }
}
