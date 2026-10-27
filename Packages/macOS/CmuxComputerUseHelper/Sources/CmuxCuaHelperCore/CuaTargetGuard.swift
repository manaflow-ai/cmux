// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Foundation

/// Checks every supplied target, including a window owned by a different pid.
struct CuaTargetGuard: Sendable {
    let policy: CuaTargetPolicy
    let resolver: any CuaTargetResolving

    func check(name: String, arguments: Data) async throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ToolError("Computer use arguments must be a JSON object.")
        }
        let hasPID = object["pid"].map { !($0 is NSNull) } ?? false
        let hasWindowID = object["window_id"].map { !($0 is NSNull) } ?? false
        if let value = object["pid"], !(value is NSNull) {
            guard let pid = integer(value), pid > 0, let nativePID = Int32(exactly: pid) else {
                throw unresolved("pid")
            }
            try check(await resolver.app(forPID: nativePID), reference: "pid \(pid)")
        }
        if let value = object["window_id"], !(value is NSNull) {
            guard let id = integer(value), id > 0, let nativeID = UInt32(exactly: id) else {
                throw unresolved("window_id")
            }
            try check(await resolver.app(forWindowID: nativeID), reference: "window \(id)")
        }
        for key in ["bundle_id", "app_bundle_id"] {
            if let value = object[key], !(value is NSNull) {
                guard let bundle = value as? String, !bundle.isEmpty else { throw unresolved(key) }
                try check(CuaTargetIdentity(bundleID: bundle, name: bundle), reference: bundle)
                try check(await resolver.app(forBundleID: bundle), reference: bundle)
            }
        }
        for key in name == "launch_app" ? ["name", "app_name"] : ["app_name"] {
            if let value = object[key], !(value is NSNull) {
                guard let reference = value as? String, !reference.isEmpty else { throw unresolved(key) }
                let app = await resolver.app(named: reference)
                try check(app, reference: reference)
                if name == "launch_app", !(object["bundle_id"] is String), let app {
                    // LaunchServices must open the bundle we checked, rather than
                    // resolving the display name a second time inside the driver.
                    object["bundle_id"] = app.bundleID
                }
            }
        }
        // A desktop input has an implicit, changing target. Require an explicit
        // pid/window so it cannot bypass the guard via global input delivery.
        if object["scope"] as? String == "desktop", !hasPID, !hasWindowID,
           Self.desktopInputTools.contains(name) {
            throw ToolError("Computer use desktop input needs an explicit app target. Use list_apps or list_windows, then provide pid or window_id.")
        }
        if name == "launch_app", let urls = object["urls"] as? [String] {
            for url in urls {
                let parts = url.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let scheme = parts[0].lowercased()
                if scheme == "cmux" || scheme.hasPrefix("cmux-") || scheme.hasPrefix("cmux+") {
                    throw ToolError("Computer use is not allowed to use cmux for safety reasons.")
                }
            }
        }
        // Unchanged calls keep their original wire bytes.
        if name != "launch_app" { return arguments }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func check(_ app: CuaTargetIdentity?, reference: String) throws {
        guard let app else { throw unresolved(reference) }
        guard policy.allows(bundleID: app.bundleID, appName: app.name) else {
            throw ToolError("Computer use is not allowed to use \(app.name) for safety reasons.")
        }
    }

    private func unresolved(_ reference: String) -> ToolError {
        ToolError("Computer use cannot resolve \(reference) to an app bundle. Use list_apps or list_windows to choose a current target.")
    }

    private func integer(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int64(number.stringValue) else { return nil }
        return result
    }

    private static let desktopInputTools: Set<String> = [
        "click", "double_click", "right_click", "drag", "scroll", "move_cursor",
        "press_key", "hotkey", "type_text", "type_text_chars",
    ]
}
