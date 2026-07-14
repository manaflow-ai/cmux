import CmuxSimulator
import Foundation

/// The `cmux simulator` namespace: the CLI face of the `simulator.*` socket
/// verbs (list / open / close). Argument parsing lives in the `CmuxSimulator`
/// package (`SimulatorCLIParser`) so it is unit-testable with `swift test`;
/// this file only normalizes handles against the live socket and formats
/// output. The whole namespace is gated app-side behind
/// `simulator.beta.enabled`, so a disabled feature refuses with guidance
/// rather than spawning anything.
extension CMUXCLI {
    func runSimulatorNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let request: SimulatorCLIRequest
        do {
            request = try SimulatorCLIParser().parse(commandArgs)
        } catch let error as SimulatorCLIParseError {
            throw CLIError(message: error.message)
        }

        switch request {
        case .help:
            print(Self.simulatorUsage)

        case .list:
            let payload = try client.sendV2(method: "simulator.list", params: [:])
            printSimulatorListPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)

        case .open(let open):
            var params: [String: Any] = [
                "device": open.deviceQuery,
                "focus": open.focus,
            ]
            let winId = try normalizeWindowHandle(open.window ?? windowOverride, client: client)
            if let winId { params["window_id"] = winId }
            if let wsId = try normalizeWorkspaceHandle(
                open.workspace,
                client: client,
                windowHandle: winId,
                allowCurrent: true
            ) {
                params["workspace_id"] = wsId
            }
            let payload = try client.sendV2(method: "simulator.open", params: params)
            let handle = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "OK"
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: "Opened simulator pane \(handle) for \(open.deviceQuery)"
            )

        case .close(let close):
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(close.window ?? windowOverride, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(
                close.workspace,
                client: client,
                windowHandle: winId,
                allowCurrent: true
            )
            if let wsId { params["workspace_id"] = wsId }
            if let surface = try normalizeSurfaceHandle(
                close.surface,
                client: client,
                workspaceHandle: wsId,
                windowHandle: winId
            ) {
                params["surface_id"] = surface
            }
            let payload = try client.sendV2(method: "simulator.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")
        }
    }

    private func printSimulatorListPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let devices = payload["devices"] as? [[String: Any]] ?? []
        guard !devices.isEmpty else {
            print("No simulator devices. Install a simulator runtime in Xcode.")
            return
        }
        for device in devices {
            let name = device["name"] as? String ?? "?"
            let state = device["state"] as? String ?? "?"
            let runtime = device["runtime_name"] as? String ?? ""
            let udid = device["udid"] as? String ?? "?"
            let unavailable = (device["available"] as? Bool ?? false) ? "" : "  (unavailable)"
            print("\(name)  \(runtime)  \(state)  \(udid)\(unavailable)")
        }
    }

    static let simulatorUsage = """
    Usage: cmux simulator <subcommand> [flags]

    Open a live iOS Simulator display as a cmux pane (experimental; enable
    "iOS Simulator Panes" in Settings → Beta Features first). cmux boots the
    device headlessly when it is shut down and only attaches when it is
    already booted; closing the pane shuts down only devices cmux booted.

    Subcommands:
      list                    List simulator devices (from simctl)
      open --device <name|udid> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus true|false]
                              Open a simulator pane for a device. --focus
                              defaults to false so the pane never steals focus.
      close [--surface <id|ref|index>] [--workspace <id|ref|index>]
                              Close a simulator pane (the workspace's only one,
                              or the one named by --surface)

    Examples:
      cmux simulator list
      cmux simulator open --device "iPhone 17 Pro"
      cmux simulator open --device DCE5B544-A3A4-418D-AF1E-AC244F465CE3 --workspace workspace:2
      cmux simulator close
    """
}
