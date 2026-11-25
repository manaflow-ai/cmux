internal import CCmuxUpdatePrewarmFFI
import Foundation

/// The staged-update pre-warm record's rules in Rust (cmux-tui/crates/cmux-update-prewarm-core,
/// `cmux_update_prewarm.h`, src/ops.rs): the marker line each pre-warm step writes and what a build's
/// first launch reads from it. Swift only reads and writes the file.
enum UpdatePrewarmRules {
    /// The marker line for `build` at `step` (`marker.encode`), or nil when Rust refuses it (an empty build).
    static func markerLine(build: String, step: StagedUpdatePrewarm.Step) -> String? {
        var request: [String: Any] = ["build": build]
        switch step {
        case .started: request["state"] = "started"
        case .main: request["state"] = "main"
        case .full: request["state"] = "full"
        case let .skipped(reason): request["state"] = "skipped"; request["reason"] = reason
        }
        return (call("marker.encode", request) as? [String: Any])?["line"] as? String
    }

    /// What `build`'s launch reads from the marker's text (`marker.verdict`; nil text: no file). A reply Rust
    /// refuses reads as not pre-warmed and leaves the file.
    static func verdict(build: String, marker: String?) -> StagedUpdatePrewarm.Verdict {
        let reply = call("marker.verdict", ["build": build, "marker": marker ?? NSNull()]) as? [String: Any]
        return StagedUpdatePrewarm.Verdict(preWarmed: reply?["pre_warmed"] as? Bool ?? false,
                                           reason: reply?["reason"] as? String ?? "no_verdict",
                                           consume: reply?["consume"] as? Bool ?? false)
    }

    /// One op (`cmux_update_prewarm_call`) on a JSON object: its reply, or nil when the op refused it.
    private static func call(_ op: String, _ request: [String: Any]) -> Any? {
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxUpdatePrewarmBytes(ptr: nil, len: 0)
        let code = op.withCString { op in
            json.withUnsafeBytes { bytes in
                cmux_update_prewarm_call(op, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &out)
            }
        }
        defer { cmux_update_prewarm_bytes_free(out) }
        guard code == CMUX_UPDATE_PREWARM_OK, let pointer = out.ptr else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: out.len), options: .fragmentsAllowed)
    }
}
