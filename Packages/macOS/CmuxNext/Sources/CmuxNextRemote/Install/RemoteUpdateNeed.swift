public import Foundation

/// The answer of the app's bundled `cmux-tui remote update-need` (cx-3r9mt): whether a machine's
/// cmux-tui is older, the same or newer. The rule lives in cmux-tui (`cmux_remote::update_need`);
/// the app only reads `need` and `reason`.
public struct RemoteUpdateNeed: Sendable, Equatable {
    /// `older`, `none` or `newer`.
    public let need: String
    public let reason: String
}

extension RemoteProbe {
    /// Asks `binary` about the machine whose `remote-probe --json` is this probe; nil when the
    /// binary cannot answer (an app whose cmux-tui predates the command), so nothing is installed.
    public func updateNeed(asking binary: URL) async -> RemoteUpdateNeed? {
        guard let result = try? await SSHProcessRunner.run([binary.path, "remote", "update-need", "--probe-json", "-"],
                                                           input: .data(Data(json.utf8)),
                                                           environment: ProcessInfo.processInfo.environment,
                                                           deadline: .seconds(10), label: "cmux-tui remote update-need"),
              result.status == 0,
              let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any],
              let need = object["need"] as? String, let reason = object["reason"] as? String else { return nil }
        return RemoteUpdateNeed(need: need, reason: reason)
    }
}
