import Foundation

extension CMUXCLI {
    /// Legacy top-level commands whose names are also action nouns in
    /// cmux-next. For these the CLI asks the server which app it is (one
    /// `system.ping`, answered off the main thread by both apps) before
    /// choosing the legacy handler or the generated verbs. Other nouns need
    /// no entry: unknown commands always try the generated verbs.
    static let actionNounsSharedWithLegacyCommands: Set<String> = [
        "agent", "app", "browser", "cloud", "notification", "pane", "settings",
        "tab", "terminal", "workspace", "workspace-group"
    ]

    /// Runs `cmux action …` and generated `cmux <noun> <verb>` commands
    /// against cmux-next. Returns false when the command is not one, so the
    /// legacy dispatch continues unchanged (and against the old app every
    /// legacy command behaves exactly as before).
    func runActionCLIIfApplicable(
        command: String,
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws -> Bool {
        let isActionCommand = command == "action"
        let isUnknownNoun = !Self.topLevelCommandNames.contains(command) && CmuxActionCLI.isCandidateNoun(command)
        let isSharedNoun = Self.actionNounsSharedWithLegacyCommands.contains(command)
        guard isActionCommand || isUnknownNoun || isSharedNoun else { return false }

        let client = SocketClient(path: socketPath)
        defer { client.close() }
        do {
            try client.connect()
            try authenticateClientIfNeeded(client, explicitPassword: explicitPassword, socketPath: socketPath)
        } catch {
            // Let the legacy path report connection problems in its usual way.
            if isActionCommand { throw error }
            return false
        }

        if isSharedNoun, !isActionCommand {
            let ping = try? client.sendV2(method: "system.ping")
            guard ping?["app"] as? String == "cmux-next" else { return false }
        }

        let cli = CmuxActionCLI(call: { method, params in
            do {
                return try client.sendV2(method: method, params: params)
            } catch let error as CLIError where error.v2Code == "method_not_found" {
                throw CmuxActionCLI.ServerLacksActions()
            } catch let error as CLIError where error.isStructuredProtocolResponse {
                throw CmuxActionCLI.ServerError(code: error.v2Code ?? "error", message: error.message)
            }
        }, jsonOutput: jsonOutput, output: { print($0) })

        do {
            if isActionCommand {
                try cli.runActionCommand(commandArgs)
                return true
            }
            return try cli.runNounCommand(noun: command, arguments: commandArgs, fallsBackOnUnknownVerb: isSharedNoun)
        } catch is CmuxActionCLI.ServerLacksActions {
            guard isActionCommand else { return false }
            throw CLIError(message: String(
                localized: "cli.action.error.unsupportedApp",
                defaultValue: "This cmux does not support 'cmux action'. It needs the cmux-next app."
            ))
        } catch let failure as CmuxActionCLI.Failure {
            throw CLIError(message: failure.message, exitCode: failure.exitCode)
        } catch let error as CmuxActionCLI.ServerError {
            throw CLIError(message: error.message, v2Code: error.code, isStructuredProtocolResponse: true)
        }
    }
}
