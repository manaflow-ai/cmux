import CmuxControlSocket
import Foundation

extension CMUXCLI {
    func runAgentManifestCommand(
        command: String,
        arguments: [String],
        client: SocketClient,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        switch command {
        case "reload-agent-manifests":
            if let unexpected = arguments.first {
                let format = String(
                    localized: "cli.agentManifests.error.unexpectedArgument",
                    defaultValue: "reload-agent-manifests does not accept arguments. Unexpected argument '%@'"
                )
                throw CLIError(message: String.localizedStringWithFormat(format, unexpected))
            }
            print(try sendV1Command("reload_agent_manifests", client: client))

        case "debug-agent-manifest":
            let parsed: AgentManifestDiagnosticArguments
            switch AgentManifestDiagnosticArguments.parse(arguments: arguments) {
            case .success(let arguments):
                parsed = arguments
            case .failure(let error):
                throw CLIError(message: error.localizedDescription)
            }

            var commandParts = ["debug_agent_manifest"]
            let ambientSurface = environment["CMUX_SURFACE_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let surface = parsed.surface
                ?? (ambientSurface?.isEmpty == false ? ambientSurface : nil) {
                commandParts.append("--surface")
                commandParts.append(socketQuote(surface))
            }
            if let osc = parsed.osc {
                commandParts.append("--osc")
                commandParts.append(socketQuote(osc))
            }
            print(try sendV1Command(commandParts.joined(separator: " "), client: client))

        default:
            preconditionFailure("Unsupported agent manifest command '\(command)'")
        }
    }

    func agentManifestCommandUsage(_ command: String) -> String {
        switch command {
        case "reload-agent-manifests":
            return String(localized: "cli.help.reloadAgentManifests", defaultValue: """
            Usage: cmux reload-agent-manifests

            Reload bundled and user agent-detection manifests in the live app.
            Invalid files are rejected and the last-known-good rules remain active.

            Example:
              cmux reload-agent-manifests
            """)
        case "debug-agent-manifest":
            return String(localized: "cli.help.debugAgentManifest", defaultValue: """
            Usage: cmux debug-agent-manifest [--surface <id|ref|index>] [--osc <sequence>]

            Capture a terminal pane and report the manifest, process matcher,
            state classification, and rule trace. This command is read-only
            and does not change focus. The surface defaults to $CMUX_SURFACE_ID.

            Example:
              cmux debug-agent-manifest
              cmux debug-agent-manifest --surface surface:2
              cmux debug-agent-manifest --osc $'\\e]9;cmux;idle\\a'
            """)
        default:
            return ""
        }
    }

}
