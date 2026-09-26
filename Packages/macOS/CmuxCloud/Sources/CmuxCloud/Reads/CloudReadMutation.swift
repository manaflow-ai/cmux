import Foundation

/// Identifies the read snapshots changed by one successful control-plane mutation.
public struct CloudReadMutation: Sendable {
    public let scope: CloudReadRequestCoordinator.Key
    let affectedPaths: Set<String>

    public init(method: String, scope: CloudReadRequestCoordinator.Key, responseData: Data) {
        self.scope = scope
        var paths: Set<String> = []
        let parts = scope.path.split(separator: "/").map(String.init)
        let createsMachine = method == "POST" && [
            "/api/vm", "/api/vm/restore", "/api/vm/base/open", "/api/vm/base/reset"
        ].contains(scope.path)
        var forksMachine = false
        if createsMachine {
            paths.insert("/api/vm")
            paths.insert("/api/coderouter/vm-usage/team")
        } else if parts.count >= 3, parts[0] == "api", parts[1] == "vm",
                  !["base", "restore", "tunnel", "publications", "domains"].contains(parts[2]) {
            let machinePath = "/api/vm/\(parts[2])"
            if parts.count == 3, method == "PATCH" || method == "DELETE" {
                paths.insert("/api/vm")
                paths.insert("/api/coderouter/vm-usage/team")
                if method == "DELETE" { paths.insert("\(machinePath)/stats") }
            } else if parts.count == 4, method == "POST", [
                "pause", "resume", "resize", "fork", "attach-endpoint", "ssh-endpoint",
                "scp-endpoint", "sessions", "exec", "open-port"
            ].contains(parts[3]) {
                // Open/exec/file-transfer routes can wake a suspended machine.
                // Other machines' samples remain valid while this one changes.
                paths.insert("/api/vm")
                paths.insert("\(machinePath)/stats")
                if parts[3] == "fork" {
                    forksMachine = true
                    paths.insert("/api/coderouter/vm-usage/team")
                }
            }
        }
        if createsMachine || forksMachine {
            if let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let id = object["id"] as? String, !id.isEmpty {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "/?#")
                if let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) {
                    paths.insert("/api/vm/\(encodedID)/stats")
                }
            }
        }
        affectedPaths = paths
    }
}
