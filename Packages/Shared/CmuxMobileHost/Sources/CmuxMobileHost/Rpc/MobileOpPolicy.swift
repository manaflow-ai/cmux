import CmuxMobileWire
import Foundation

/// Default-deny authorization for ops from a phone (skills/cmux-socket-policy
/// relay rules, b5-mac-host.md section 3).
///
/// - Only listed ops run; anything else (including ops added later) is `auth.forbidden`.
/// - Command-bearing params are refused on every op, before anything else.
/// - Params outside the op's schema are refused.
/// - Every id must resolve in this host's current tree (scope check).
/// - Terminal-spawning ops run only when `allowsTerminalSpawn` is set after a
///   live verification; they still never take a cwd, environment or URL.
public struct MobileOpPolicy: Sendable {
    /// Params that could run or open something on the Mac. Refused everywhere.
    public static let commandParams: Set<String> = [
        "command", "initial_command", "argv", "args", "env", "environment", "cwd", "shell", "script",
        "tmux_start_command", "pane_start_command", "url",
    ]

    /// Ops a phone may send and the params each takes.
    public static let allowedParams: [String: Set<String>] = [
        "workspace.rename": ["workspace", "name"],
        "workspace.tab.close": ["tab"],
        "workspace.create": ["host", "name"],
        "workspace.tab.create": ["workspace", "pane", "kind"],
    ]

    static let spawningOps: Set<String> = ["workspace.create", "workspace.tab.create"]

    public var hostID: String
    public var allowsTerminalSpawn: Bool

    public init(hostID: String, allowsTerminalSpawn: Bool = false) {
        self.hostID = hostID
        self.allowsTerminalSpawn = allowsTerminalSpawn
    }

    public func evaluate(op: String, params: JSONValue, state: MobileWorkspaceState) -> Result<MobileDaemonOp, MobileOpRejection> {
        guard let allowed = Self.allowedParams[op] else {
            return .failure(Self.forbidden("\(op) is not available to a phone"))
        }
        guard let object = params.objectValue else {
            return .failure(Self.invalid("params must be an object"))
        }
        let commandBearing = Set(object.keys).intersection(Self.commandParams)
        guard commandBearing.isEmpty else {
            return .failure(Self.forbidden("\(op) does not take \(commandBearing.sorted().joined(separator: ", ")) from a phone"))
        }
        let extra = Set(object.keys).subtracting(allowed)
        guard extra.isEmpty else {
            return .failure(Self.invalid("\(op) does not take \(extra.sorted().joined(separator: ", "))"))
        }
        if Self.spawningOps.contains(op), !allowsTerminalSpawn {
            return .failure(MobileOpRejection(
                code: "auth.forbidden",
                message: "creating terminals from a phone is disabled until it is verified on this Mac",
                details: .object(["reason": .string("spawn_unverified")])))
        }
        switch op {
        case "workspace.rename":
            guard let workspace = object["workspace"]?.stringValue, Self.matches(workspace, prefix: "ws_"),
                  let name = Self.name(object["name"]) else {
                return .failure(Self.invalid("workspace.rename needs a ws_ id and a name of 1 to 200 characters"))
            }
            guard state.workspace(workspace) != nil else { return .failure(Self.notFound("workspace.not_found", workspace)) }
            return .success(.renameWorkspace(workspace: workspace, name: name))
        case "workspace.tab.close":
            guard let tab = object["tab"]?.stringValue, Self.matches(tab, prefix: "tab_") else {
                return .failure(Self.invalid("workspace.tab.close needs a tab_ id"))
            }
            guard state.tab(tab) != nil else { return .failure(Self.notFound("workspace.tab_not_found", tab)) }
            return .success(.closeTab(tab: tab))
        case "workspace.create":
            if let host = object["host"], host.stringValue != hostID {
                return .failure(Self.invalid("params.host names another host"))
            }
            if object["name"] != nil, Self.name(object["name"]) == nil {
                return .failure(Self.invalid("name must be 1 to 200 characters"))
            }
            return .success(.createWorkspace(name: Self.name(object["name"])))
        case "workspace.tab.create":
            guard let workspace = object["workspace"]?.stringValue, Self.matches(workspace, prefix: "ws_"),
                  let kindName = object["kind"]?.stringValue, let kind = MobileTab.Kind(rawValue: kindName),
                  kind == .terminal || kind == .browser else {
                return .failure(Self.invalid("workspace.tab.create needs a ws_ id and kind terminal or browser"))
            }
            guard let target = state.workspace(workspace) else { return .failure(Self.notFound("workspace.not_found", workspace)) }
            var pane: String?
            if let value = object["pane"] {
                guard let id = value.stringValue, Self.matches(id, prefix: "pane_"),
                      target.panes.contains(where: { $0.id == id }) else {
                    return .failure(Self.notFound("workspace.not_found", value.stringValue ?? "pane"))
                }
                pane = id
            }
            return .success(.createTab(workspace: workspace, pane: pane, kind: kind, url: nil))
        default:
            return .failure(Self.forbidden("\(op) is not available to a phone"))
        }
    }

    // MARK: Helpers

    static func matches(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        return (2...64).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func name(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...200).contains(trimmed.count) ? trimmed : nil
    }

    static func forbidden(_ message: String) -> MobileOpRejection {
        MobileOpRejection(code: "auth.forbidden", message: message)
    }

    static func invalid(_ message: String) -> MobileOpRejection {
        MobileOpRejection(code: "validation.invalid", message: message)
    }

    static func notFound(_ code: String, _ id: String) -> MobileOpRejection {
        MobileOpRejection(code: code, message: "\(id) is not on this host")
    }
}
