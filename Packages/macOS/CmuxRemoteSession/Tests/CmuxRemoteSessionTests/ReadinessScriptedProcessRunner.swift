import Foundation
@testable import CmuxRemoteSession

/// A remote host whose SSH transport always works (the platform probe and
/// every ControlMaster command succeed) while the cmux pieces behind it vary.
///
/// This is the precondition of https://github.com/manaflow-ai/cmux/issues/12813:
/// direct `ssh` and the ControlMaster probe succeed, yet the daemon, reverse
/// relay, or proxy never becomes ready.
final class ReadinessScriptedProcessRunner: RemoteSessionProcessRunning, Sendable {
    private let daemon: ReadinessScriptedDaemon

    init(daemon: ReadinessScriptedDaemon) {
        self.daemon = daemon
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let command = request.arguments.last ?? ""
        if command.contains(RemoteSessionCoordinator.remotePlatformProbeOSMarker) {
            return RemoteCommandResult(status: 0, stdout: platformProbeOutput, stderr: "")
        }
        if command.contains("serve --stdio"),
           case .installed(let capabilities) = daemon {
            return RemoteCommandResult(
                status: 0,
                stdout: Self.helloResponse(capabilities: capabilities),
                stderr: ""
            )
        }
        if Self.isControlCommand("forward", in: request.arguments) {
            // No shared master to multiplex onto: the coordinator falls back
            // to its standalone `ssh -N -R` relay transport.
            return RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr: "Control socket connect(/tmp/cmux-ssh-test): No such file or directory"
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    private var platformProbeOutput: String {
        let installed: Bool
        if case .installed = daemon { installed = true } else { installed = false }
        return [
            "\(RemoteSessionCoordinator.remotePlatformProbeHomeMarker)/Users/remote",
            "\(RemoteSessionCoordinator.remotePlatformProbeOSMarker)Darwin",
            "\(RemoteSessionCoordinator.remotePlatformProbeArchMarker)x86_64",
            "\(RemoteSessionCoordinator.remotePlatformProbeExistsMarker)\(installed ? "yes" : "no")",
            "\(RemoteSessionCoordinator.remotePlatformProbeSizeMarker)\(installed ? "4096" : "0")",
        ].joined(separator: "\n")
    }

    private static func helloResponse(capabilities: [String]) -> String {
        let payload: [String: Any] = [
            "id": 1,
            "ok": true,
            "result": [
                "name": "cmuxd-remote",
                "version": "test",
                "capabilities": capabilities,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}
