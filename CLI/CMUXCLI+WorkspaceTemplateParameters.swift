import CmuxFoundation
import Foundation

extension CMUXCLI {
    static let workspaceCreateHelpText = String(
        localized: "cli.workspace.create.help",
        defaultValue: """
        Usage: cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--env KEY=VALUE]... [--env-file <path>]... [--param KEY=VALUE]... [--layout <json>] [--window <id|ref|index>] [--focus <true|false>] [--group <id|ref>] [--group-placement afterCurrent|top|end] [--group-reference <workspace>]

        Create a new workspace in the caller's window.

        Flags:
          --name <title>       Set a custom name for the new workspace
          --description <text> Set a custom description for the new workspace
          --cwd <path>         Set the working directory for the new workspace
          --command <text>     Send text+Enter to the new workspace after creation
          --env KEY=VALUE      Set a workspace environment variable. Repeatable.
                               Reserved CMUX_* variables cannot be overridden.
          --env-file <path>    Load KEY=VALUE lines from a file. Repeatable.
          --param KEY=VALUE    Set a {{variable}} used by workspace strings. Repeatable.
          --param KEY          Import KEY from the invoking shell environment.
          --layout <json>      Create workspace with a predefined split layout.
                               Layout surfaces define their own commands.
          --window <id|ref|index> Target window (default: caller's window)
          --focus <true|false> Focus the new workspace (default: false)
          --group <id|ref>     Add the new workspace to a workspace group
          --group-placement afterCurrent|top|end Placement within --group (default: top)
          --group-reference <workspace> Reference workspace for afterCurrent placement

        Examples:
          cmux new-workspace
          cmux new-workspace --name "Build Server"
          cmux new-workspace --cwd . --command "npm test"
          cmux new-workspace --name "Dev {{ticket}}" --param ticket=BERKS-87
        """
    )

    struct WorkspaceTemplateParameterOptions {
        let values: [String: String]
        let remaining: [String]
    }

    /// Parses repeatable `--param KEY=VALUE`, `--param=KEY=VALUE`, and
    /// `--param KEY` arguments. The last value wins; the value-less form imports
    /// that key from the invoking CLI process environment.
    func parseWorkspaceTemplateParameterOptions(
        _ args: [String],
        commandName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WorkspaceTemplateParameterOptions {
        var values: [String: String] = [:]
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                pastTerminator = true
                remaining.append(argument)
                index += 1
                continue
            }
            guard !pastTerminator else {
                remaining.append(argument)
                index += 1
                continue
            }

            let rawParameter: String?
            if argument == "--param" {
                guard index + 1 < args.count else {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.workspace.templateParameter.error.requiresValue",
                            defaultValue: "%@: --param requires KEY=VALUE or KEY"
                        ),
                        locale: .current,
                        commandName
                    ))
                }
                rawParameter = args[index + 1]
                index += 2
            } else if argument.hasPrefix("--param=") {
                rawParameter = String(argument.dropFirst("--param=".count))
                index += 1
            } else {
                rawParameter = nil
            }

            guard let rawParameter else {
                remaining.append(argument)
                index += 1
                continue
            }
            let parameter = try parseWorkspaceTemplateParameter(
                rawParameter,
                commandName: commandName,
                environment: environment
            )
            values[parameter.key] = parameter.value
        }
        return WorkspaceTemplateParameterOptions(values: values, remaining: remaining)
    }

    func resolveWorkspaceCommandTemplate(
        _ command: String,
        templateParameters: [String: String],
        workspaceEnvironment: [String: String],
        commandName: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let literalWorkspaceEnvironment = workspaceEnvironment.filter { _, value in
            !CmuxTemplate(value).containsVariables
        }
        do {
            return try CmuxTemplateResolver(
                explicitValues: templateParameters,
                workspaceEnvironment: literalWorkspaceEnvironment,
                processEnvironment: processEnvironment
            ).resolve(CmuxTemplate(command))
        } catch CmuxTemplateResolutionError.missingVariables(let names) {
            throw CLIError(
                message: String(
                    format: String(
                        localized: "cli.workspace.templateParameter.error.missing",
                        defaultValue: "%@: missing workspace template parameters: %@"
                    ),
                    locale: .current,
                    commandName,
                    names.joined(separator: ", ")
                ),
                v2Code: "missing_parameters"
            )
        }
    }

    private func parseWorkspaceTemplateParameter(
        _ raw: String,
        commandName: String,
        environment: [String: String]
    ) throws -> (key: String, value: String) {
        let key: String
        let explicitValue: String?
        if let equals = raw.firstIndex(of: "=") {
            key = String(raw[..<equals]).trimmingCharacters(in: .whitespaces)
            explicitValue = String(raw[raw.index(after: equals)...])
        } else {
            key = raw.trimmingCharacters(in: .whitespaces)
            explicitValue = nil
        }

        guard CmuxTemplateVariable.isValidName(key) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.templateParameter.error.invalidName",
                    defaultValue: "%@: invalid template parameter name '%@'"
                ),
                locale: .current,
                commandName,
                key
            ))
        }
        if let explicitValue {
            return (key, explicitValue)
        }
        guard let environmentValue = environment[key] else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.templateParameter.error.environmentMissing",
                    defaultValue: "%@: --param %@ could not import an unset environment variable"
                ),
                locale: .current,
                commandName,
                key
            ))
        }
        return (key, environmentValue)
    }
}
