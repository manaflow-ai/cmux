import Foundation

/// Non-destructive settings of a CloudDO machine on the app-server link (cmuxterm-hq#6236 brief 09).
/// Classic /api/vm accepts neither the CloudDO machine ID nor these requests.
public nonisolated enum CloudMachineSettings {
    /// CloudDO commits a rename with a machine projection. An unrelated or incomplete answer must
    /// never update the local row; the next list can reconcile after an uncertain response.
    public static func rename(_ machine: String, to name: String, ops: CloudAppOp) async throws {
        let answer = try await ops("cloud.machine.rename",
                                   .object(["machine": .string(machine), "name": .string(name)]), UUID().uuidString, .user)
        guard answer["machine"]?["id"]?.stringValue == machine,
              answer["machine"]?["name"]?.stringValue == name else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.machine.rename answered no matching machine")
        }
    }

    /// CloudDO stores seconds, while the existing macOS/CLI action accepts minutes.
    /// The server acknowledges the exact value before the app reflects it.
    public static func setIdlePause(_ machine: String, minutes: Int, ops: CloudAppOp) async throws {
        guard (0...10080).contains(minutes) else {
            throw CloudAppOpFailure(code: "cmux.cloud.validation_invalid", message: "idle pause must be between 0 and 10080 minutes")
        }
        let seconds = minutes * 60
        let answer = try await ops("cloud.machine.idle_policy.set",
                                   .object(["machine": .string(machine), "idle_seconds": .number(Double(seconds))]),
                                   UUID().uuidString, .user)
        guard answer["machine"]?["id"]?.stringValue == machine,
              answer["machine"]?["idle_policy"]?["idle_seconds"]?.doubleValue == Double(seconds) else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.machine.idle_policy.set answered no matching policy")
        }
    }
}
