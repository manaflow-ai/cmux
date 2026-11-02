// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// An upstream capability manifest, version 3, for one agent session under
/// `ask` (docs/computer-use-approvals.md, "Sessions"). The pinned driver
/// (b0968e1, `cua-driver-core/src/session_manifest.rs`) parses it with
/// `deny_unknown_fields` as YAML, so the JSON written here holds only fields
/// it knows:
///
///   {"version":3,"expires_after":"<N>s","idle_timeout":"<N>s",
///    "allow":{"tools":[...]},
///    "resources":{"apps":[{"bundle_id":B}|{"executable":E}],"desktop":{"display":false}}}
///
/// - `allow.tools`: every tool of the driver's inventory that upstream has
///   reviewed (an unreviewed name fails the whole manifest), canonical and
///   distinct (`type_text_chars` is `type_text`), except opaque dispatch
///   (`run_script`, `replay_trajectory`).
/// - `resources.apps`: the session's grants plus the client's saved list;
///   each entry covers all of the app's windows, and never termination.
/// - `desktop.display: false`: no desktop-wide capture or input.
/// - `expires_after` and `idle_timeout`: what is left of the session's
///   lifetime (8 h at the start) and 30 min of idle, at most that lifetime.
struct CapabilityManifest: Sendable, Equatable {
    var tools: [String]
    var apps: [ApprovalApp]
    var expiresAfterSeconds: Int
    var idleTimeoutSeconds: Int

    /// The `ask` driver's compatibility context, which upstream requires a
    /// manifest under `bounded`: one reviewed observe tool and no app. The
    /// worker never calls outside a session, so it allows nothing useful.
    static let compatibility = CapabilityManifest(tools: ["get_screen_size"], apps: [],
                                                  expiresAfterSeconds: 24 * 60 * 60,
                                                  idleTimeoutSeconds: 24 * 60 * 60)

    /// The manifest's file contents (JSON, which is YAML).
    var data: Data {
        let apps: [[String: Any]] = apps.map { app in
            if let bundleID = app.bundleID { return ["bundle_id": bundleID] }
            return ["executable": app.executable ?? ""]
        }
        let object: [String: Any] = [
            "version": 3,
            "expires_after": "\(max(1, expiresAfterSeconds))s",
            "idle_timeout": "\(max(1, min(idleTimeoutSeconds, expiresAfterSeconds)))s",
            "allow": ["tools": tools],
            "resources": ["apps": apps, "desktop": ["display": false]],
        ]
        return (try? CanonicalJSON.encode(object)) ?? Data()
    }

    /// The `allow.tools` list for an inventory (`tools/list`: an array of
    /// tools, or `{"tools":[...]}`), sorted.
    static func allowedTools(inventory: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: inventory)
        let tools = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }.map { $0 == "type_text_chars" ? "type_text" : $0 }
        return Set(names).filter { ReviewedTools.risk[$0] != nil && !CuaTargetGuard.opaqueDispatchTools.contains($0) }
            .sorted()
    }
}

/// Upstream's reviewed risk classes, copied from the pinned driver
/// (b0968e1, `cua-driver-core/src/authorization.rs`, `advertised_risk_for`).
/// Upstream refuses any tool outside this table, and a manifest that lists
/// one does not load; the approval card shows the class.
struct ReviewedTools: Sendable {
    static let risk: [String: String] = {
        var table: [String: String] = [:]
        for name in [
            "get_screen_size", "get_cursor_position", "get_config", "get_session", "list_sessions",
            "get_session_state", "get_agent_cursor_state", "get_recording_state", "check_for_update",
            "health_report", "probe",
        ] { table[name] = "R0" }
        for name in [
            "click", "double_click", "right_click", "drag", "scroll", "move_cursor", "mouse_button_down",
            "mouse_button_up", "mouse_drag", "parallel_mouse_drag", "type_text", "type_text_chars", "press_key",
            "hotkey", "set_value", "invoke_menu", "launch_app", "bring_to_front", "set_window_frame",
            "start_session", "end_session", "set_agent_cursor_enabled", "set_agent_cursor_motion",
            "set_agent_cursor_theme", "clipboard_write",
        ] { table[name] = "R1" }
        for name in [
            "zoom", "clipboard_read", "list_apps", "list_windows", "debug_window_info", "check_permissions",
            "get_accessibility_tree", "verify_state", "set_config", "escalate_session", "start_recording",
            "get_browser_state", "browser_prepare", "browser_navigate", "browser_click", "browser_type",
            "browser_pointer", "history_status", "history_query", "parse_visual_regions",
        ] { table[name] = "R2" }
        for name in [
            "get_desktop_state", "get_window_state", "kill_app", "stop_recording", "replay_trajectory",
            "install_ffmpeg", "install_extension", "page", "browser_dialog", "browser_set_input_files",
            "browser_download",
        ] { table[name] = "R3" }
        return table
    }()
}

/// Writes manifests 0600 into a directory private to this user
/// (`PrivateDirectory`). The driver reads a manifest once, when it creates
/// the session, so each file is removed right after.
struct ManifestStore: Sendable {
    let directory: String

    enum StoreError: Error, CustomStringConvertible {
        case directoryNotPrivate(String)
        case write(String, Int32)

        var description: String {
            switch self {
            case .directoryNotPrivate(let path): "the manifest directory \(path) is not private to this user"
            case .write(let path, let code): "cannot write the manifest \(path): errno \(code)"
            }
        }
    }

    /// A per-process directory under this user's temp directory.
    static func defaultDirectory() -> String? {
        PrivateDirectory.userTemporaryRoot().map { "\($0)/cmux-cu-manifests/\(getpid())" }
    }

    /// Writes `data` as a new file (never over an existing one or through a
    /// symlink) and returns its path.
    func write(_ data: Data, name: String) throws -> String {
        guard PrivateDirectory.prepare(directory) else { throw StoreError.directoryNotPrivate(directory) }
        let path = directory + "/" + name
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.write(path, errno) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base + offset, raw.count - offset)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return -1 }
                offset += count
            }
            return offset
        }
        guard written == data.count else {
            let failure = errno
            unlink(path)
            throw StoreError.write(path, failure)
        }
        return path
    }

    func remove(_ path: String) { unlink(path) }
}
