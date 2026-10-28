import Foundation

extension AgentLaunchEnvironmentPolicy {
    /// Environment updates that undo a cmux Claude launch's NODE_OPTIONS
    /// injection inherited by a long-lived process such as the app itself.
    ///
    /// A cmux Claude launch prepends a `--require` restore preload to
    /// NODE_OPTIONS and records the original value in `CMUX_ORIGINAL_NODE_OPTIONS*`.
    /// A process started from inside that session inherits the preload path and
    /// passes it to every terminal it spawns, so `node` fails once the file is gone.
    ///
    /// Returns an empty dictionary when nothing needs to change. A `nil` value
    /// means the key should be unset.
    public func inheritedNodeOptionsRepair(from env: [String: String]) -> [String: String?] {
        var updates: [String: String?] = [:]
        if let nodeOptions = env["NODE_OPTIONS"], containsCmuxNodeOptionsRestoreModule(nodeOptions) {
            updates["NODE_OPTIONS"] = .some(selectedNodeOptions(from: env))
        }
        for key in ["CMUX_ORIGINAL_NODE_OPTIONS", "CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"] where env[key] != nil {
            updates[key] = .some(nil)
        }
        return updates
    }

    func selectedNodeOptions(from env: [String: String]) -> String? {
        let marker = env["CMUX_ORIGINAL_NODE_OPTIONS_PRESENT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch marker?.isEmpty == false ? marker : nil {
        case "1":
            return sanitizedNodeOptions(env["CMUX_ORIGINAL_NODE_OPTIONS"])
        case "0":
            return sanitizedNodeOptions(env["NODE_OPTIONS"])
        default:
            return sanitizedNodeOptions(env["NODE_OPTIONS"])
        }
    }
}
