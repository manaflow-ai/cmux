import Foundation
import CmuxSurfaceCatalogModel

/// Parses the native New Machine subset shared by the launcher and package tests.
public struct CloudMachineCreateArgumentParser: Sendable {
    /// Creates the stateless parser.
    public init() {}

    /// Recognizes supported create/open arguments; unsupported forms stay on the CLI.
    /// - Parameter arguments: Arguments after the executable name.
    /// - Returns: A typed invocation, or nil for unsupported or invalid arguments.
    public func parse(arguments: [String]) -> CloudMachineCreateInvocation? {
        guard arguments.count >= 2, arguments[0] == "vm" else { return nil }
        let verb = arguments[1]
        guard verb == "new" || verb == "open" else { return nil }
        if verb == "open" {
            guard arguments.count >= 3, !arguments[2].isEmpty, !arguments[2].hasPrefix("-") else { return nil }
            var focus = true
            var workspaceID: UUID?
            var windowID: UUID?
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--focus":
                    guard index + 1 < arguments.count else { return nil }
                    switch arguments[index + 1].lowercased() {
                    case "true", "1", "yes": focus = true
                    case "false", "0", "no": focus = false
                    default: return nil
                    }
                    index += 1
                case "--workspace":
                    guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                    workspaceID = value; index += 1
                case "--window":
                    guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                    windowID = value; index += 1
                default: return nil
                }
                index += 1
            }
            guard let workspaceID else { return nil }
            return CloudMachineCreateInvocation(
                machineID: arguments[2], kind: nil, memoryMb: nil, displayName: nil,
                networkPolicy: nil, agentUpdates: nil, workspaceID: workspaceID,
                focus: focus, windowID: windowID
            )
        }
        var kind: VMMachineKind?
        var memoryMb: Int?
        var displayName: String?
        var networkPolicy: CloudNetworkPolicy?
        var agentUpdates: CloudAgentUpdates?
        var focus = true
        var workspaceID: UUID?
        var windowID: UUID?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--desktop": kind = .desktop
            case "--base", "--no-desktop": return nil
            case "--size":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { return nil }
                memoryMb = value; index += 1
            case "--name":
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                displayName = value.isEmpty ? nil : value; index += 1
            case "--network-policy":
                guard index + 1 < arguments.count,
                      let data = arguments[index + 1].data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let policy = try? CloudNetworkPolicy(foundationObject: object) else { return nil }
                networkPolicy = policy; index += 1
            case "--agent-updates":
                guard index + 1 < arguments.count, let value = CloudAgentUpdates(rawValue: arguments[index + 1]) else { return nil }
                agentUpdates = value; index += 1
            case "--focus":
                guard index + 1 < arguments.count else { return nil }
                switch arguments[index + 1].lowercased() {
                case "true", "1", "yes": focus = true
                case "false", "0", "no": focus = false
                default: return nil
                }
                index += 1
            case "--workspace":
                guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                workspaceID = value; index += 1
            case "--window":
                guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                windowID = value; index += 1
            default: return nil
            }
            index += 1
        }
        guard let workspaceID else { return nil }
        return CloudMachineCreateInvocation(
            machineID: nil, kind: kind, memoryMb: memoryMb, displayName: displayName,
            networkPolicy: networkPolicy, agentUpdates: agentUpdates,
            workspaceID: workspaceID, focus: focus, windowID: windowID
        )
    }

    /// Returns the stable server idempotency key for one logical create.
    /// - Parameter operationID: The coordinator-owned identity retained across retries.
    /// - Returns: A namespaced, lowercased operation UUID.
    public func idempotencyKey(operationID: UUID) -> String {
        "app-" + operationID.uuidString.lowercased()
    }

}
