import CmuxSettings
import Foundation

private func sanitizedInitialEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.reduce(into: [:]) { result, pair in
        let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains("\0"),
              !key.contains("="),
              !pair.value.contains("\0") else {
            return
        }
        result[key] = pair.value
    }
}

extension TerminalController {
    nonisolated static var workspaceCreateTabManagerUnavailableMessage: String {
        String(
            localized: "socket.workspace.create.tabManagerUnavailable",
            defaultValue: "TabManager not available"
        )
    }

    /// Parameter names accepted by the shared `workspace.create` execution
    /// path. Keeping this list at the command boundary prevents a sidebar (or
    /// any other caller) from believing a misspelled option was honored.
    nonisolated static let workspaceCreateSupportedParameterKeys: Set<String> = [
        "window_id", "workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id",
        "operation_id", "title", "name", "description", "cwd", "working_directory",
        "command", "initial_command", "initial_env", "workspace_env", "env", "layout",
        "focus", "eager_load_terminal", "auto_refresh_metadata", "group_id",
        "group_placement", "placement", "group_reference_workspace_id",
        "reference_workspace_id",
    ]

    /// Canonicalizes the aliases accepted by the CLI and rejects options that
    /// the shared create path cannot honor. The caller supplies the selected
    /// workspace directory so relative `cwd` values have deterministic meaning.
    @discardableResult
    nonisolated func v2NormalizeWorkspaceCreateParams(
        _ params: inout [String: Any],
        relativeTo baseDirectory: String?,
        resolveWorkingDirectory: Bool = true
    ) -> V2CallResult? {
        if let unsupported = params.keys
            .filter({ !Self.workspaceCreateSupportedParameterKeys.contains($0) })
            .sorted()
            .first {
            let message = String(
                format: String(
                    localized: "socket.workspace.create.unsupportedParameter",
                    defaultValue: "Unsupported workspace.create parameter `%@`."
                ),
                locale: .current,
                unsupported
            )
            return .err(
                code: "unsupported_param",
                message: message,
                data: [
                    "method": "workspace.create",
                    "unsupported_param": unsupported,
                    "supported_params": Self.workspaceCreateSupportedParameterKeys.sorted(),
                ]
            )
        }

        let stringKeys = [
            "operation_id", "title", "name", "description", "cwd", "working_directory",
            "command", "initial_command", "group_placement", "placement",
            "group_reference_workspace_id", "reference_workspace_id",
        ]
        for key in stringKeys {
            guard let value = params[key], !(value is NSNull) else { continue }
            guard value is String else {
                return v2WorkspaceCreateInvalidParameter(
                    key: key,
                    expected: String(
                        localized: "socket.workspace.create.expected.string",
                        defaultValue: "a string"
                    )
                )
            }
        }

        for key in ["initial_env", "workspace_env", "env"] {
            guard let value = params[key], !(value is NSNull) else { continue }
            let values: [String: Any]?
            if let dictionary = value as? [String: String] {
                values = dictionary.mapValues { $0 }
            } else {
                values = value as? [String: Any]
            }
            guard let values,
                  values.values.allSatisfy({ $0 is String }) else {
                return v2WorkspaceCreateInvalidParameter(
                    key: key,
                    expected: String(
                        localized: "socket.workspace.create.expected.stringMap",
                        defaultValue: "an object of string values"
                    )
                )
            }
        }

        if let layout = params["layout"], !(layout is NSNull),
           !(layout is [String: Any]), !(layout is [String: String]) {
            return v2WorkspaceCreateInvalidParameter(
                key: "layout",
                expected: String(
                    localized: "socket.workspace.create.expected.jsonObject",
                    defaultValue: "a JSON object"
                )
            )
        }

        let title = v2WorkspaceCreateStringValue(params["title"])
        let name = v2WorkspaceCreateStringValue(params["name"])
        if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["title"] = name
        }
        params.removeValue(forKey: "name")

        let workingDirectory = v2WorkspaceCreateStringValue(params["working_directory"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyCwd = v2WorkspaceCreateStringValue(params["cwd"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryDirectory = workingDirectory?.isEmpty == false ? workingDirectory : nil
        let legacyDirectory = legacyCwd?.isEmpty == false ? legacyCwd : nil
        if let primaryDirectory, let legacyDirectory,
           primaryDirectory != legacyDirectory {
            return v2WorkspaceCreateConflictingParameters(
                first: "working_directory",
                second: "cwd"
            )
        }
        if let rawDirectory = primaryDirectory ?? legacyDirectory {
            guard !rawDirectory.utf8.contains(0) else {
                return v2WorkspaceCreateInvalidParameter(
                    key: primaryDirectory != nil ? "working_directory" : "cwd",
                    expected: String(
                        localized: "socket.workspace.create.expected.pathWithoutNUL",
                        defaultValue: "a path without NUL bytes"
                    )
                )
            }
            if resolveWorkingDirectory {
                if let resolvedDirectory = Self.v2ResolvedWorkspaceCreateWorkingDirectory(
                    rawDirectory,
                    relativeTo: baseDirectory
                ) {
                    params["working_directory"] = resolvedDirectory
                } else {
                    params.removeValue(forKey: "working_directory")
                }
            } else {
                // The mobile data plane validates the caller's path before any
                // canonicalization. In particular, it intentionally rejects
                // relative paths and dot components; preserve the raw alias
                // until that validator has produced an absolute directory.
                params["working_directory"] = rawDirectory
            }
        }
        params.removeValue(forKey: "cwd")

        if let legacyEnvironment = params["env"], !(legacyEnvironment is NSNull) {
            if let currentEnvironment = params["workspace_env"],
               !(currentEnvironment is NSNull),
               v2WorkspaceCreateStringMap(legacyEnvironment) != v2WorkspaceCreateStringMap(currentEnvironment) {
                return v2WorkspaceCreateConflictingParameters(
                    first: "workspace_env",
                    second: "env"
                )
            }
            if params["workspace_env"] == nil || params["workspace_env"] is NSNull {
                params["workspace_env"] = legacyEnvironment
            }
        }
        params.removeValue(forKey: "env")

        let command = v2WorkspaceCreateStringValue(params["command"])
        let initialCommand = v2WorkspaceCreateStringValue(params["initial_command"])
        let hasCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasCommand, hasInitialCommand {
            return v2WorkspaceCreateConflictingParameters(
                first: "command",
                second: "initial_command"
            )
        }

        let hasLayout = {
            guard let layout = params["layout"], !(layout is NSNull) else { return false }
            if let dictionary = layout as? [String: Any] { return !dictionary.isEmpty }
            if let dictionary = layout as? [String: String] { return !dictionary.isEmpty }
            return true
        }()
        if hasLayout, hasCommand {
            return v2WorkspaceCreateConflictingParameters(first: "command", second: "layout")
        }
        if hasLayout, hasInitialCommand {
            return v2WorkspaceCreateConflictingParameters(first: "initial_command", second: "layout")
        }
        if hasLayout,
           let initialEnvironment = params["initial_env"],
           !(initialEnvironment is NSNull),
           v2WorkspaceCreateStringMap(initialEnvironment)?.isEmpty == false {
            return v2WorkspaceCreateConflictingParameters(first: "initial_env", second: "layout")
        }
        return nil
    }

    /// Expands and canonicalizes a workspace-create path without changing the
    /// legacy helper used by mobile validation (which intentionally rejects
    /// relative paths before a host directory is available).
    nonisolated static func v2ResolvedWorkspaceCreateWorkingDirectory(
        _ raw: String?,
        relativeTo baseDirectory: String?
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = {
            guard let baseDirectory,
                  !baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return home
            }
            let expanded = NSString(string: baseDirectory).expandingTildeInPath
            guard (expanded as NSString).isAbsolutePath else { return home }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }()
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: base)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    private nonisolated func v2WorkspaceCreateInvalidParameter(
        key: String,
        expected: String
    ) -> V2CallResult {
        let detail = String(
            format: String(
                localized: "socket.workspace.create.invalidParameter",
                defaultValue: "Parameter `%@` must be %@."
            ),
            locale: .current,
            key,
            expected
        )
        return .err(
            code: "invalid_params",
            message: detail,
            data: ["method": "workspace.create", "parameter": key]
        )
    }

    private nonisolated func v2WorkspaceCreateConflictingParameters(
        first: String,
        second: String
    ) -> V2CallResult {
        let detail = String(
            format: String(
                localized: "socket.workspace.create.conflictingParameters",
                defaultValue: "Parameters `%@` and `%@` cannot be used together."
            ),
            locale: .current,
            first,
            second
        )
        return .err(
            code: "invalid_params",
            message: detail,
            data: [
                "method": "workspace.create",
                "parameters": [first, second],
            ]
        )
    }

    private nonisolated func v2WorkspaceCreateStringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private nonisolated func v2WorkspaceCreateStringMap(_ value: Any?) -> [String: String]? {
        guard let value, !(value is NSNull) else { return nil }
        if let dictionary = value as? [String: String] { return dictionary }
        guard let dictionary = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            guard let string = value as? String else { return nil }
            result[key] = string
        }
        return result
    }

    struct WorkspaceCreateExecutionPreparation {
        let title: String?
        let description: String?
        let initialCommand: String?
        let command: String?
        let initialEnvironment: [String: String]
        let workspaceEnvironment: [String: String]
        let workingDirectory: String?
        let groupID: UUID?
        let groupPlacement: WorkspaceGroupNewPlacement?
        let groupReferenceWorkspaceID: UUID?
        let layoutNode: CmuxLayoutNode?
        let shouldFocus: Bool
        let shouldEagerLoadTerminal: Bool
        let shouldAutoRefreshMetadata: Bool
    }

    enum WorkspaceCreateExecutionPreparationOutcome {
        case failure(V2CallResult)
        case ready(WorkspaceCreateExecutionPreparation)
    }

    func v2PrepareWorkspaceCreateExecution(
        params: [String: Any],
        preparation: WorkspaceCreatePreparation,
        workingDirectory: String?
    ) -> WorkspaceCreateExecutionPreparationOutcome {
        let requestedInitialCommand = v2RawString(params, "initial_command")
        let initialCommand = requestedInitialCommand.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : WorkspaceInitialCommandLoginShell.wrap($0)
        }
        let initialEnvironment = sanitizedInitialEnvironment(v2StringMap(params, "initial_env") ?? [:])
        let requestedCommand = v2RawString(params, "command")
        let command = requestedCommand.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let workspaceEnvironment = Workspace.sanitizedWorkspaceEnvironment(
            v2StringMap(params, "workspace_env") ?? [:]
        )
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let string = raw as? String else {
                return .failure(.err(code: "invalid_params", message: "cwd must be a string", data: nil))
            }
            cwd = Self.v2ResolvedWorkspaceCreateWorkingDirectory(
                string,
                relativeTo: preparation.tabManager.selectedWorkspace?.currentDirectory
            )
        } else {
            cwd = nil
        }

        let requestedTitle = (v2RawString(params, "title") ?? v2RawString(params, "name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = requestedTitle?.isEmpty == false ? requestedTitle : nil
        let description = v2RawString(params, "description")
        let groupID = v2UUID(params, "group_id")
        if v2HasNonNullParam(params, "group_id"), groupID == nil {
            return .failure(.err(code: "invalid_params", message: "Missing or invalid group_id", data: nil))
        }
        let hasGroupPlacement = v2HasNonNullParam(params, "group_placement")
            || v2HasNonNullParam(params, "placement")
        let hasGroupReference = v2HasNonNullParam(params, "group_reference_workspace_id")
            || v2HasNonNullParam(params, "reference_workspace_id")
        if groupID == nil, hasGroupPlacement || hasGroupReference {
            return .failure(.err(
                code: "invalid_params",
                message: "group_id is required for group placement",
                data: nil
            ))
        }
        let rawGroupPlacement = v2RawString(params, "group_placement")
            ?? (groupID == nil ? nil : v2RawString(params, "placement"))
        let groupPlacement = WorkspaceGroupNewPlacement(rawString: rawGroupPlacement)
        if let rawGroupPlacement,
           !rawGroupPlacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           groupPlacement == nil {
            return .failure(.err(
                code: "invalid_params",
                message: "Invalid group_placement",
                data: ["group_placement": rawGroupPlacement]
            ))
        }
        let groupReferenceWorkspaceID: UUID?
        if v2HasNonNullParam(params, "group_reference_workspace_id") {
            guard let parsed = v2UUID(params, "group_reference_workspace_id") else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Missing or invalid group_reference_workspace_id",
                    data: nil
                ))
            }
            groupReferenceWorkspaceID = parsed
        } else if v2HasNonNullParam(params, "reference_workspace_id") {
            guard let parsed = v2UUID(params, "reference_workspace_id") else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Missing or invalid group_reference_workspace_id",
                    data: nil
                ))
            }
            groupReferenceWorkspaceID = parsed
        } else {
            groupReferenceWorkspaceID = nil
        }

        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "layout must be a valid JSON object",
                    data: nil
                ))
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Invalid layout: \(error.localizedDescription)",
                    data: nil
                ))
            }
        }

        if let groupID {
            let validation = v2MainSync {
                let groupExists = preparation.tabManager.workspaceGroups.contains { $0.id == groupID }
                let referenceIsMember = groupReferenceWorkspaceID.map { referenceID in
                    preparation.tabManager.tabs.contains { $0.id == referenceID && $0.groupId == groupID }
                } ?? true
                return (groupExists, referenceIsMember)
            }
            guard validation.0 else {
                return .failure(.err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupID.uuidString]
                ))
            }
            guard validation.1 else {
                return .failure(.err(
                    code: "invalid_params",
                    message: controlWorkspaceGroupStrings().invalidReferenceWorkspace,
                    data: ["group_reference_workspace_id": groupReferenceWorkspaceID?.uuidString ?? ""]
                ))
            }
        }

        return .ready(WorkspaceCreateExecutionPreparation(
            title: title,
            description: description,
            initialCommand: initialCommand,
            command: command,
            initialEnvironment: initialEnvironment,
            workspaceEnvironment: workspaceEnvironment,
            workingDirectory: cwd,
            groupID: groupID,
            groupPlacement: groupPlacement,
            groupReferenceWorkspaceID: groupReferenceWorkspaceID,
            layoutNode: layoutNode,
            shouldFocus: v2FocusAllowed(requested: v2Bool(params, "focus") ?? false),
            shouldEagerLoadTerminal: v2Bool(params, "eager_load_terminal")
                ?? !v2FocusAllowed(requested: v2Bool(params, "focus") ?? false),
            shouldAutoRefreshMetadata: v2Bool(params, "auto_refresh_metadata") ?? true
        ))
    }
}
