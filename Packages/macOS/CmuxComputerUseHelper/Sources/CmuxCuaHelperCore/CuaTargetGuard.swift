// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Foundation

/// Checks every supplied target, including a window owned by a different pid.
struct CuaTargetGuard: Sendable {
    let policy: CuaTargetPolicy
    let resolver: any CuaTargetResolving

    /// A checked call: the arguments to send and every app it targets, as
    /// resolved here (pid, window or bundle id; never the agent's words).
    struct Checked: Sendable {
        let arguments: Data
        /// Distinct by bundle id, in the order the call names them.
        let targets: [CuaTargetIdentity]
    }

    func check(name: String, arguments: Data) async throws -> Data {
        try await resolve(name: name, arguments: arguments).arguments
    }

    /// Checks the call like `check`, and returns the apps it resolved.
    func resolve(name: String, arguments: Data) async throws -> Checked {
        let log = TargetLog()
        let checked = try await check(name: name, arguments: arguments, log: log)
        return Checked(arguments: checked, targets: log.apps)
    }

    private func check(name: String, arguments: Data, log: TargetLog) async throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ToolError("Computer use arguments must be a JSON object.")
        }
        // These run other tools from content this guard cannot check (a
        // script, a recorded trajectory), so their targets are never seen.
        try checkDispatch(name)
        // A batch runs each step through the driver's own registry, so every
        // nested target must pass here first. Upstream matches `app` and
        // `window` names loosely (substring), which this guard cannot repeat
        // exactly, so a batch must name its windows by pid and window_id.
        if Self.batchTools.contains(name) {
            try await checkBatch(object, log: log)
            return arguments
        }
        try await checkTargets(in: object, name: name, log: log)
        for key in name == "launch_app" ? ["name", "app_name"] : ["app_name"] {
            if let value = object[key], !(value is NSNull) {
                guard let reference = value as? String, !reference.isEmpty else { throw unresolved(key) }
                let app = await resolver.app(named: reference)
                try check(app, reference: reference, log: log)
                if name == "launch_app", !(object["bundle_id"] is String), let app {
                    // LaunchServices must open the bundle we checked, rather than
                    // resolving the display name a second time inside the driver.
                    object["bundle_id"] = app.bundleID
                }
            }
        }
        // A URL never opens cmux: launch_app's urls, and browser_navigate's url through the
        // browser's protocol handler (review 3 #4).
        var urls = name == "launch_app" ? (object["urls"] as? [String] ?? []) : []
        if name == "browser_navigate", let url = object["url"] as? String { urls.append(url) }
        for url in urls where Self.opensCmux(url) {
            throw ToolError("Computer use is not allowed to use cmux for safety reasons.")
        }
        // Unchanged calls keep their original wire bytes.
        if name != "launch_app" { return arguments }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Checks the pid, window, bundle id and element token targets of one
    /// argument object. `name` is the tool, or nil for an object nested in a batch.
    private func checkTargets(in object: [String: Any], name: String?, log: TargetLog) async throws {
        let object = try targetFields(in: object, name: name)
        let hasPID = object["pid"].map { !($0 is NSNull) } ?? false
        let hasWindowID = object["window_id"].map { !($0 is NSNull) } ?? false
        if let value = object["pid"], !(value is NSNull) {
            guard let pid = integer(value), pid > 0, let nativePID = Int32(exactly: pid) else {
                throw unresolved("pid")
            }
            try check(await resolver.app(forPID: nativePID), reference: "pid \(pid)", log: log)
        }
        if let value = object["window_id"], !(value is NSNull) {
            guard let id = integer(value), id > 0, let nativeID = UInt32(exactly: id) else {
                throw unresolved("window_id")
            }
            try check(await resolver.app(forWindowID: nativeID), reference: "window \(id)", log: log)
        }
        for key in ["bundle_id", "app_bundle_id"] {
            if let value = object[key], !(value is NSNull) {
                guard let bundle = value as? String, !bundle.isEmpty else { throw unresolved(key) }
                try check(CuaTargetIdentity(bundleID: bundle, name: bundle), reference: bundle, log: nil)
                try check(await resolver.app(forBundleID: bundle), reference: bundle, log: log)
            }
        }
        // A desktop input has an implicit, changing target. Require an explicit
        // pid/window so it cannot bypass the guard via global input delivery.
        // In a batch the step's tool is not known here, so every desktop scope needs one.
        if object["scope"] as? String == "desktop", !hasPID, !hasWindowID,
           name.map(Self.desktopInputTools.contains) ?? true {
            throw ToolError("Computer use desktop input needs an explicit app target. Use list_apps or list_windows, then provide pid or window_id.")
        }
        // Since v0.35 upstream takes an element_token without a pid and acts
        // on the token's own window, which this guard never resolved.
        if let token = object["element_token"], !(token is NSNull), !hasPID {
            throw ToolError("Computer use needs the pid with element_token. Pass the pid of the window you read the token from.")
        }
    }

    /// Match action_target.rs in the pinned driver before it normalizes targets.
    /// Keep the original call bytes, but check the exact fields the driver uses.
    private func targetFields(in object: [String: Any], name: String?) throws -> [String: Any] {
        // Name selectors use the driver's loose matching. Require exact ids.
        for key in ["app", "window"] {
            if let value = object[key], !(value is NSNull) { throw unsupportedTarget() }
        }
        if let scope = object["scope"], !(scope is NSNull) {
            guard let scope = scope as? String, ["window", "desktop"].contains(scope) else {
                throw unsupportedTarget()
            }
        }
        guard let value = object["target"] else { return object }
        guard name.map(Self.typedTargetTools.contains) ?? true,
              !["scope", "pid", "window_id"].contains(where: { object.keys.contains($0) }),
              let target = value as? [String: Any], let kind = target["kind"] as? String else {
            throw unsupportedTarget()
        }
        var fields = object
        fields.removeValue(forKey: "target")
        switch kind {
        case "window":
            guard Set(target.keys) == ["kind", "pid", "window_id"],
                  let pid = target["pid"].flatMap(integer), pid > 0, Int32(exactly: pid) != nil,
                  let window = target["window_id"].flatMap(integer), window > 0, UInt32(exactly: window) != nil else {
                throw unsupportedTarget()
            }
            fields["pid"] = target["pid"]
            fields["window_id"] = target["window_id"]
        case "desktop":
            guard Set(target.keys) == ["kind", "display_id"], target["display_id"] as? String == "primary" else {
                throw unsupportedTarget()
            }
            fields["scope"] = "desktop"
        default:
            // v0.38 has no app target kind. Refuse new kinds until reviewed.
            throw unsupportedTarget()
        }
        return fields
    }

    private func checkDispatch(_ name: String) throws {
        if Self.opaqueDispatchTools.contains(name) {
            throw ToolError("Computer use does not allow \(name) in cmux. Call the tools directly, or use run_steps with pid and window_id.")
        }
    }

    private func unsupportedTarget() -> ToolError {
        ToolError(String(localized: "computerUse.target.unsupported", defaultValue: "Computer use cannot check this target shape. Use pid and window_id, or target with kind window, pid, and window_id.", bundle: localizationBundle))
    }

    private var localizationBundle: Bundle {
        // SwiftPM tests use .module. The helper app keeps the same resource
        // bundle under Contents/Resources, as required by code signing.
        if let url = Bundle.main.url(forResource: "CmuxComputerUseHelper_CmuxCuaHelperCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }

    private func checkBatch(_ object: [String: Any], log: TargetLog) async throws {
        let defaults = object.filter { ["pid", "window_id"].contains($0.key) }
        func walk(_ value: Any, depth: Int) async throws {
            guard depth < 16 else { throw ToolError("Computer use batch arguments are nested too deeply.") }
            if let object = value as? [String: Any] {
                if let tool = object["tool"] as? String { try checkDispatch(tool) }
                for tool in object.keys { try checkDispatch(tool) }
                // A nested browser_navigate (any step's `url`) never opens cmux either.
                if let url = object["url"] as? String, Self.opensCmux(url) {
                    throw ToolError("Computer use is not allowed to use cmux for safety reasons.")
                }
                for key in ["app", "window"] {
                    if let selector = object[key], !(selector is NSNull) {
                        throw ToolError("Computer use batches must name each window by pid and window_id, not by `\(key)`. Use list_windows first.")
                    }
                }
                // Upstream v0.38 batch_tools.rs gives an untargeted step the
                // batch's pid/window_id. An explicit step target stands alone.
                var fields = object
                let targetKeys = ["pid", "window_id", "target", "scope", "app", "window",
                                  "bundle_id", "app_bundle_id", "app_name"]
                if !targetKeys.contains(where: { key in
                    object[key].map { !($0 is NSNull) } ?? false
                }) {
                    fields.merge(defaults) { _, inherited in inherited }
                }
                try await checkTargets(in: fields, name: nil, log: log)
                for (key, nested) in object where key != "app_name" {
                    try await walk(nested, depth: depth + 1)
                }
                if let reference = object["app_name"], !(reference is NSNull) {
                    guard let reference = reference as? String, !reference.isEmpty else { throw unresolved("app_name") }
                    try check(await resolver.app(named: reference), reference: reference, log: log)
                }
            } else if let array = value as? [Any] {
                for nested in array { try await walk(nested, depth: depth + 1) }
            }
        }
        try await walk(object, depth: 0)
    }

    /// Refuses an unresolved or never-allowed app; records an allowed one in `log`.
    private func check(_ app: CuaTargetIdentity?, reference: String, log: TargetLog?) throws {
        guard let app else { throw unresolved(reference) }
        guard policy.allows(bundleID: app.bundleID, appName: app.name) else {
            throw ToolError("Computer use is not allowed to use \(app.name) for safety reasons.")
        }
        log?.record(app)
    }

    /// The apps one check resolved. Each check runs its awaits in sequence,
    /// so the log is never written concurrently.
    final class TargetLog {
        private(set) var apps: [CuaTargetIdentity] = []

        func record(_ app: CuaTargetIdentity) {
            guard !apps.contains(where: { $0.bundleID.lowercased() == app.bundleID.lowercased() }) else { return }
            apps.append(app)
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

    /// Whether `url` opens cmux (`cmux:`, `cmux-…:`, `cmux+…:`), read as a browser reads it
    /// (the URL Standard): leading and trailing C0 controls and spaces stripped, every ASCII tab
    /// and newline removed, the scheme case-insensitive.
    static func opensCmux(_ url: String) -> Bool {
        let scalars = Array(url.unicodeScalars)
        let isC0OrSpace: (Unicode.Scalar) -> Bool = { $0.value <= 0x20 }
        guard let first = scalars.firstIndex(where: { !isC0OrSpace($0) }),
              let last = scalars.lastIndex(where: { !isC0OrSpace($0) }) else { return false }
        var cleaned = String.UnicodeScalarView()
        for scalar in scalars[first...last] where !["\t", "\n", "\r"].contains(scalar) { cleaned.append(scalar) }
        // The colon as a code point, not a Character: a combining mark after it would join it into
        // one grapheme and hide it from a Character split, while a browser still reads the scheme.
        guard let colon = cleaned.firstIndex(of: ":") else { return false }
        let scheme = String(String.UnicodeScalarView(cleaned[..<colon])).lowercased()
        return scheme == "cmux" || scheme.hasPrefix("cmux-") || scheme.hasPrefix("cmux+")
    }

    /// Tools that run other tools from content outside their arguments.
    static let opaqueDispatchTools: Set<String> = ["run_script", "replay_trajectory"]
    /// Tools that run nested tool calls given in their arguments (run_actions
    /// is upstream's hidden alias of run_steps).
    static let batchTools: Set<String> = ["run_steps", "run_actions"]

    private static let typedTargetTools: Set<String> = [
        "move_cursor", "click", "drag", "scroll", "type_text", "press_key", "hotkey", "type_text_chars",
    ]

    private static let desktopInputTools: Set<String> = [
        "click", "double_click", "right_click", "drag", "scroll", "move_cursor",
        "press_key", "hotkey", "type_text", "type_text_chars",
    ]
}
