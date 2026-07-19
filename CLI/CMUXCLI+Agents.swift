import CmuxFoundation
import Darwin
import Foundation

struct AgentSessionProviderSpecification: Sendable, Equatable {
    var name: String
    var displayName: String
    var sessionStoreSuffix: String
    var configDirEnvOverride: String?
}

private struct AgentSessionConfiguredProvider: Sendable {
    var id: String
    var name: String
}

struct AgentSessionProviderCatalogLimitError: Error {
    var maximumCount: Int
    var observedAtLeast: Int
}

struct AgentSessionProviderCollisionError: Error {
    var firstProvider: String
    var secondProvider: String
}

struct AgentPrettyJSONStreamWriter {
    private static let flushThresholdBytes = 64 * 1_024

    private let handle: FileHandle
    private var buffer: Data
    private var fieldCount = 0
    private var arrayElementCount: Int?

    init(handle: FileHandle) throws {
        self.handle = handle
        self.buffer = Data()
        buffer.reserveCapacity(Self.flushThresholdBytes)
        buffer.append(contentsOf: "{".utf8)
    }

    mutating func writeValueField(name: String, value: Any) throws {
        try writeValueField(name: name, encodedValue: Self.encodeJSONObject(value))
    }

    mutating func writeValueField<T: Encodable>(
        name: String,
        value: T,
        encoder: JSONEncoder
    ) throws {
        try writeValueField(name: name, encodedValue: encoder.encode(value))
    }

    mutating func beginArrayField(name: String) throws {
        precondition(arrayElementCount == nil)
        try beginField(name: name)
        try write(Data("[".utf8))
        arrayElementCount = 0
    }

    mutating func writeArrayElement(_ value: Any) throws {
        let encodedValue = try autoreleasepool {
            try Self.encodeJSONObject(value)
        }
        try writeArrayElement(encodedValue: encodedValue)
    }

    mutating func writeArrayElement<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder
    ) throws {
        let encodedValue = try autoreleasepool {
            try encoder.encode(value)
        }
        try writeArrayElement(encodedValue: encodedValue)
    }

    mutating func writeArrayElements(_ values: [[String: Any]]) throws {
        guard !values.isEmpty else { return }
        let encodedValues = try autoreleasepool {
            try JSONSerialization.data(
                withJSONObject: values,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        try writeEncodedArrayElements(encodedValues, count: values.count)
    }

    mutating func writeArrayElements<T: Encodable>(
        _ values: [T],
        encoder: JSONEncoder
    ) throws {
        guard !values.isEmpty else { return }
        let encodedValues = try autoreleasepool {
            try encoder.encode(values)
        }
        try writeEncodedArrayElements(encodedValues, count: values.count)
    }

    mutating func endArray() throws {
        guard let arrayElementCount else { preconditionFailure("No JSON array is open") }
        if arrayElementCount == 0 {
            try write(Data("\n\n  ]".utf8))
        } else {
            try write(Data("\n  ]".utf8))
        }
        self.arrayElementCount = nil
    }

    mutating func finish() throws {
        precondition(arrayElementCount == nil)
        try write(Data("\n}\n".utf8))
        try flush()
    }

    private mutating func writeValueField(name: String, encodedValue: Data) throws {
        precondition(arrayElementCount == nil)
        try beginField(name: name)
        try writeIndented(encodedValue, continuationIndent: "  ")
    }

    private mutating func writeArrayElement(encodedValue: Data) throws {
        guard let count = arrayElementCount else { preconditionFailure("No JSON array is open") }
        try write(Data((count == 0 ? "\n    " : ",\n    ").utf8))
        try writeIndented(encodedValue, continuationIndent: "    ")
        arrayElementCount = count + 1
    }

    private mutating func writeEncodedArrayElements(_ encodedValues: Data, count: Int) throws {
        guard let currentCount = arrayElementCount else {
            preconditionFailure("No JSON array is open")
        }
        guard encodedValues.first == 91, encodedValues.last == 93 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let elements = encodedValues.dropFirst().dropLast()
        guard !elements.isEmpty else { return }
        try write(Data((currentCount == 0 ? "\n    " : ",\n    ").utf8))
        try write(Data(elements))
        arrayElementCount = currentCount + count
    }

    private mutating func beginField(name: String) throws {
        try write(Data((fieldCount == 0 ? "\n  " : ",\n  ").utf8))
        try write(Self.encodeJSONString(name))
        try write(Data(" : ".utf8))
        fieldCount += 1
    }

    private mutating func writeIndented(_ data: Data, continuationIndent: String) throws {
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { try write(Data(("\n" + continuationIndent).utf8)) }
            if !line.isEmpty { try write(Data(line)) }
        }
    }

    private mutating func write(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= Self.flushThresholdBytes {
            try flush()
        }
    }

    private mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private static func encodeJSONObject(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) || value is NSNull
                || value is String || value is NSNumber else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func encodeJSONString(_ value: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}

extension CMUXCLI {
    enum AgentsValueOptionContext {
        case agentsList
        case sessionsList
        case tree
    }

    enum AgentsCommandInvocation: String {
        case agents
        case sessions
    }

    private enum AgentsCommandOutputShape: String {
        case list
        case tree
    }

    func runAgentsCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        terminalObservations: [CmuxAgentTerminalObservation] = [],
        invocation: AgentsCommandInvocation = .agents,
        runtimeInspectionError: Error? = nil,
        runtimeSocketPath: String? = nil
    ) throws {
        let subcommand = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let outputShape: AgentsCommandOutputShape = subcommand == "tree" ? .tree : .list
        let structuredOutputRequested = jsonOutput || commandArgs.contains("--json")
        do {
            if let runtimeInspectionError {
                throw agentsRuntimeUnavailableCLIError(
                    runtimeInspectionError,
                    socketPath: runtimeSocketPath
                )
            }
            if outputShape == .tree {
                try runAgentsTreeCommand(
                    commandArgs: Array(commandArgs.dropFirst()),
                    jsonOutput: jsonOutput,
                    processEnv: processEnv,
                    fileManager: fileManager,
                    terminalObservations: terminalObservations
                )
                return
            }
            try runSessionsCommand(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput,
                processEnv: processEnv,
                fileManager: fileManager,
                terminalObservations: terminalObservations,
                invocation: invocation
            )
        } catch {
            let commandError = agentsCommandError(
                error,
                invocation: invocation,
                outputShape: outputShape
            )
            if structuredOutputRequested {
                agentsWriteStructuredError(commandError, outputShape: outputShape)
            }
            throw commandError
        }
    }

    private func agentsRuntimeUnavailableCLIError(
        _ error: Error,
        socketPath: String?
    ) -> CLIError {
        let source = error as? CLIError ?? CLIError(message: String(describing: error))
        return CLIError(
            message: source.message,
            exitCode: source.exitCode,
            v2Code: "agent_runtime_unavailable",
            structuredFields: CLIErrorStructuredFields(path: socketPath)
        )
    }

    private func agentsCommandError(
        _ error: Error,
        invocation: AgentsCommandInvocation,
        outputShape: AgentsCommandOutputShape
    ) -> CLIError {
        let source = error as? CLIError ?? CLIError(
            message: String(describing: error),
            v2Code: "internal_error"
        )
        let targetPrefix = "\(invocation.rawValue) \(outputShape.rawValue):"
        let knownPrefixes = [
            "agents list:",
            "sessions list:",
            "agents tree:",
            "sessions tree:",
            "agents:",
            "sessions:",
        ]
        let message: String
        if let prefix = knownPrefixes.first(where: { source.message.hasPrefix($0) }) {
            message = targetPrefix + String(source.message.dropFirst(prefix.count))
        } else if source.message.hasPrefix(targetPrefix) {
            message = source.message
        } else {
            message = "\(targetPrefix) \(source.message)"
        }
        return CLIError(
            message: message,
            exitCode: source.exitCode,
            v2Code: source.v2Code,
            structuredFields: source.structuredFields
        )
    }

    private func agentsWriteStructuredError(
        _ error: CLIError,
        outputShape: AgentsCommandOutputShape
    ) {
        var structuredError = error.structuredFields?.jsonObject ?? [:]
        structuredError["code"] = error.v2Code ?? "invalid_arguments"
        structuredError["message"] = error.message
        var payload: [String: Any] = [
            "schema_version": 2,
            "error": structuredError,
        ]
        switch outputShape {
        case .list:
            payload["sessions"] = []
        case .tree:
            payload["nodes"] = []
            payload["edges"] = []
        }
        cliWriteStdout(jsonString(payload) + "\n")
    }

    func agentsUsage() -> String {
        String(localized: "cli.sessions.usage", defaultValue: """
        Usage: cmux agents list [options]
               cmux agents tree [options]
               cmux agents [options]

        Print saved session lifecycle plus cached live terminal state.
        With a cmux socket, this queries runtime identity and cached observations once.
        Without a socket, it reads saved hook state from ~/.cmuxterm.
        Inside cmux, default output is scoped to that running app process.
        Pass --all to inspect cross-runtime history.

        `agents tree` renders process-spawn and conversation-fork relationships.
        Add --json for a flat, versioned nodes-and-edges graph.

        Options:
          --agent <name>        Filter to one agent, for example codex or claude
          --session <id>        Filter to one agent session id
          --workspace <id>      Filter to one saved workspace id
          --surface <id>        Filter to one saved surface id
          --state-dir <path>    Override hook state directory
          --state <state>       Filter by effective state
          --activity <state>    Filter by busy, idle, or unknown activity
          --work-kind <kind>    Filter by an active workload kind
          --all                 Print all matches
          --json                Print structured JSON

        List options:
          --cwd <text>          Filter by saved cwd or launch working directory
          --codex-home <path>   Override the default Codex home used for transcript checks
          --limit <n>           Limit rows (default: 100; with --all: unlimited)

        Tree options:
          --relation <kind>     Filter edges to spawned, forked, or resumed
          --depth <n>           Limit rendered tree depth (default: 64; maximum: 4096)
          --max-nodes <n>       Cap graph nodes (default: 10000; maximum: 20000)

        Codex rows include whether the saved id exists in CODEX_HOME/session_index.jsonl
        and whether a matching transcript file exists under CODEX_HOME/sessions or
        CODEX_HOME/archived_sessions.

        Compatibility aliases:
          cmux sessions [list|tree] [options]
          cmux sessions debug [options]
          cmux session-debug [options]
        """)
    }

    func sessionsUsage() -> String { agentsUsage() }

    func agentsWriteStoreWarnings(_ warnings: [AgentHookSessionStoreLoadWarning]) {
        for warning in warnings {
            let format = switch warning.fallback {
            case .legacy:
                String(
                    localized: "cli.agents.warning.authoritativeSnapshotDecodeFailed.legacy",
                    defaultValue: "Warning [%@]: saved %@ agent state at %@ is damaged; using the last complete fallback, so newer sessions may be missing."
                )
            case .registry:
                String(
                    localized: "cli.agents.warning.legacySourceImportFailed.registry",
                    defaultValue: "Warning [%@]: saved %@ agent state at %@ could not be imported; using the last complete registry snapshot, so newer sessions may be missing."
                )
            }
            cliWriteStderr(String(
                format: format,
                warning.code.rawValue,
                warning.provider,
                warning.path
            ) + "\n")
        }
    }

    func agentsStoreLoadCLIError(
        _ failure: AgentHookSessionStoreLoadFailure,
        context: AgentsValueOptionContext
    ) -> CLIError {
        let isTreeContext = switch context {
        case .tree: true
        case .agentsList, .sessionsList: false
        }
        let isGraphBudget = isTreeContext
            && (failure.scope == .legacyGraphNodes || failure.scope == .registryGraphNodes)
        let externalCode = isGraphBudget
            ? "agent_graph_node_budget_exceeded"
            : failure.code.rawValue
        let failureHasLegacyScope = switch failure.scope {
        case .legacyFile?, .legacySessions?, .legacyGraphNodes?, .legacyRecord?: true
        default: false
        }
        let isLegacyStorageLimit = !isGraphBudget && failureHasLegacyScope
        let canonicalPath = isLegacyStorageLimit
            ? (failure.canonicalPath ?? URL(fileURLWithPath: failure.path).deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
                .path)
            : nil
        let storageGuidance: String? = if failure.code == .storageLimitExceeded {
            if isGraphBudget {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.graph",
                        defaultValue: "Narrow the selection with --agent %@ or raise --max-nodes, up to %lld."
                    ),
                    failure.provider,
                    Self.agentsTreeHardMaximumNodes
                )
            } else if let canonicalPath {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.legacy",
                        defaultValue: "Move %@ aside without deleting it, then rerun so cmux can rebuild it from %@. If that database has no %@ rows, keep the moved file and restore it before proceeding."
                    ),
                    failure.path,
                    canonicalPath,
                    failure.provider
                )
            } else {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.canonical",
                        defaultValue: "Retry with --agent %@ to narrow the selection; inspect the canonical store at %@ before changing it."
                    ),
                    failure.provider,
                    failure.path
                )
            }
        } else {
            nil
        }
        let message: String
        if failure.code == .storageLimitExceeded,
           let scope = failure.scope,
           let storageGuidance {
            if let observedBytes = failure.observedBytes,
               let maximumBytes = failure.maximumBytes,
               let sessionID = failure.sessionID {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceeded.session",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit for session %@ (%lld bytes observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    sessionID,
                    observedBytes,
                    maximumBytes,
                    storageGuidance
                )
            } else if let observedBytes = failure.observedBytes,
                      let maximumBytes = failure.maximumBytes {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceeded",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit (%lld bytes observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    observedBytes,
                    maximumBytes,
                    storageGuidance
                )
            } else if let observedCount = failure.observedCount,
                      let maximumCount = failure.maximumCount,
                      let sessionID = failure.sessionID {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceededCount.session",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit for session %@ (%lld entries observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    sessionID,
                    observedCount,
                    maximumCount,
                    storageGuidance
                )
            } else if let observedCount = failure.observedCount,
                      let maximumCount = failure.maximumCount {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceededCount",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit (%lld entries observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    observedCount,
                    maximumCount,
                    storageGuidance
                )
            } else {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storeLoadFailed",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ could not be read and no complete fallback is available"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path
                )
            }
        } else {
            message = String(
                format: String(
                    localized: "cli.agents.error.storeLoadFailed",
                    defaultValue: "agents: [%@] saved %@ agent state at %@ could not be read and no complete fallback is available"
                ),
                externalCode,
                failure.provider,
                failure.path
            )
        }

        let recoveryAction: String? = if storageGuidance != nil {
            if isGraphBudget {
                "narrow_graph_selection"
            } else if isLegacyStorageLimit {
                "move_legacy_file_aside"
            } else {
                "narrow_agent_selection"
            }
        } else {
            nil
        }
        return CLIError(
            message: message,
            v2Code: externalCode,
            structuredFields: CLIErrorStructuredFields(
                provider: failure.provider,
                path: failure.path,
                scope: failure.scope?.rawValue,
                sessionID: failure.sessionID,
                observedBytes: failure.observedBytes,
                maximumBytes: failure.maximumBytes,
                observedCount: failure.observedCount,
                maximumCount: failure.maximumCount,
                guidance: storageGuidance,
                recoveryAction: recoveryAction,
                canonicalPath: canonicalPath,
                limit: isGraphBudget ? failure.maximumCount.flatMap(Int.init(exactly:)) : nil,
                observedAtLeast: isGraphBudget ? failure.observedCount.flatMap(Int.init(exactly:)) : nil
            )
        )
    }

    func agentsStateUnavailableCLIError(
        stateDirectory: String,
        context: AgentsValueOptionContext
    ) -> CLIError {
        let commandName = switch context {
        case .agentsList: "agents list"
        case .sessionsList: "sessions list"
        case .tree: "agents tree"
        }
        let message = String(
            format: String(
                localized: "cli.agents.error.stateUnavailable",
                defaultValue: "%@: saved agent state at %@ is unavailable"
            ),
            commandName,
            stateDirectory
        )
        return CLIError(
            message: message,
            v2Code: "agent_state_unavailable",
            structuredFields: CLIErrorStructuredFields(path: stateDirectory)
        )
    }

    func sessionsListEncodableJSONObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }

    func decodeAgentTerminalObservations(
        _ response: [String: Any],
        expectedRuntimeID: String?
    ) throws -> [CmuxAgentTerminalObservation] {
        guard let runtimeID = response["runtime_id"] as? String,
              expectedRuntimeID == nil || runtimeID == expectedRuntimeID else {
            throw CLIError(message: String(
                localized: "cli.agents.error.runtimeMismatch",
                defaultValue: "agents: live observation runtime does not match the connected cmux instance"
            ))
        }
        guard let observations = response["observations"] as? [Any],
              JSONSerialization.isValidJSONObject(observations) else { return [] }
        let data = try JSONSerialization.data(withJSONObject: observations)
        return try JSONDecoder().decode([CmuxAgentTerminalObservation].self, from: data)
    }

    func agentSessionProviderSelection(
        for requestedAgent: String,
        availableProviderIDs: [String] = [],
        terminalObservations: [CmuxAgentTerminalObservation]
    ) -> AgentSessionProviderSelection {
        let trimmed = requestedAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact configured/registry ids own their spelling. This must happen
        // before static alias expansion so a custom provider literally named
        // `cursor-agent` remains queryable instead of becoming `cursor`.
        if let exact = availableProviderIDs.first(where: { $0 == trimmed }) {
            return AgentSessionProviderSelection(
                providerID: exact,
                exactObservationProviderID: exact
            )
        }
        let normalized = agentsNormalizedAgentID(requestedAgent)
        if normalized == "claude" || normalized == "claude-code" {
            return AgentSessionProviderSelection(
                providerID: "claude",
                exactObservationProviderID: nil
            )
        }
        // Ollama has live terminal observations and native restore support, but
        // no hook sidecar. Accept the canonical filter even when no app socket
        // is available so empty offline list/tree queries remain well-formed.
        if normalized == "ollama" {
            return AgentSessionProviderSelection(
                providerID: "ollama",
                exactObservationProviderID: nil
            )
        }
        if let definition = Self.agentDef(named: normalized) {
            return AgentSessionProviderSelection(
                providerID: definition.name,
                exactObservationProviderID: nil
            )
        }
        let configuredMatches = Set(availableProviderIDs.filter {
            agentsNormalizedAgentID($0) == normalized
        })
        if configuredMatches.count == 1 {
            let providerID = configuredMatches.first
            return AgentSessionProviderSelection(
                providerID: providerID,
                exactObservationProviderID: nil,
                caseFoldedObservationProviderID: providerID
            )
        }
        let observedProviders = Set(terminalObservations.compactMap { observation -> String? in
            guard agentTerminalObservation(observation, matchesAnyAgentID: [normalized]) else {
                return nil
            }
            return observation.sessionProviderID
        })
        guard observedProviders.count == 1 else {
            return AgentSessionProviderSelection(
                providerID: nil,
                exactObservationProviderID: nil
            )
        }
        return AgentSessionProviderSelection(
            providerID: observedProviders.first,
            exactObservationProviderID: nil
        )
    }

    /// Builds the complete offline inspection catalog without enumerating the
    /// state directory. Static providers win over config, the nearest project
    /// config wins over the global config, and configured names win over the
    /// registry's identifier fallback.
    func agentSessionProviderSpecifications(
        stateDirectory: String,
        homeDirectory: String,
        requestedAgent: String? = nil,
        processEnv: [String: String],
        fileManager: FileManager
    ) throws -> [AgentSessionProviderSpecification] {
        var specifications = [
            AgentSessionProviderSpecification(
                name: "claude",
                displayName: "Claude Code",
                sessionStoreSuffix: "claude",
                configDirEnvOverride: "CLAUDE_CONFIG_DIR"
            ),
            AgentSessionProviderSpecification(
                name: "ollama",
                displayName: "Ollama",
                sessionStoreSuffix: "ollama",
                configDirEnvOverride: nil
            ),
        ]
        specifications.append(contentsOf: Self.agentDefs.map {
            AgentSessionProviderSpecification(
                name: $0.name,
                displayName: $0.displayName,
                sessionStoreSuffix: $0.sessionStoreSuffix,
                configDirEnvOverride: $0.configDirEnvOverride
            )
        })
        let staticProviderIDs = Set(specifications.map(\.name))
        // These IDs are built-in hook providers and also own app-side Vault
        // registrations. Config may rename them for display, but must retain
        // the built-in sidecar and hook metadata.
        let configurableStaticProviderIDs: Set<String> = [
            "pi", "grok", "antigravity", "ollama", "omp", "campfire",
        ]
        let exactRequestedProviderID = requestedAgent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var staticProviderIDBySidecarKey: [String: String] = [:]
        for specification in specifications {
            staticProviderIDBySidecarKey[specification.name.lowercased()] = specification.name
            staticProviderIDBySidecarKey[specification.sessionStoreSuffix.lowercased()] = specification.name
        }
        var indexByProviderID = Dictionary(
            uniqueKeysWithValues: specifications.enumerated().map { ($0.element.name, $0.offset) }
        )
        var providerIDBySidecarKey = Dictionary(
            uniqueKeysWithValues: specifications.map {
                ($0.sessionStoreSuffix.lowercased(), $0.name)
            }
        )
        var dynamicProviderCount = 0

        func include(_ provider: AgentSessionConfiguredProvider, replacesConfigured: Bool) throws {
            if staticProviderIDs.contains(provider.id) {
                guard replacesConfigured,
                      configurableStaticProviderIDs.contains(provider.id),
                      let index = indexByProviderID[provider.id] else { return }
                specifications[index].displayName = provider.name
                return
            }
            let sidecarKey = provider.id.lowercased()
            if let staticProviderID = staticProviderIDBySidecarKey[sidecarKey] {
                throw AgentSessionProviderCollisionError(
                    firstProvider: staticProviderID,
                    secondProvider: provider.id
                )
            }
            if let existingProviderID = providerIDBySidecarKey[sidecarKey],
               existingProviderID != provider.id {
                throw AgentSessionProviderCollisionError(
                    firstProvider: existingProviderID,
                    secondProvider: provider.id
                )
            }
            let specification = AgentSessionProviderSpecification(
                name: provider.id,
                displayName: provider.name,
                sessionStoreSuffix: provider.id,
                configDirEnvOverride: nil
            )
            if let index = indexByProviderID[provider.id] {
                if replacesConfigured { specifications[index] = specification }
                return
            }
            guard dynamicProviderCount < CmuxAgentSessionRegistry.maximumProviderEnumerationCount else {
                throw AgentSessionProviderCatalogLimitError(
                    maximumCount: CmuxAgentSessionRegistry.maximumProviderEnumerationCount,
                    observedAtLeast: dynamicProviderCount + 1
                )
            }
            indexByProviderID[provider.id] = specifications.count
            providerIDBySidecarKey[sidecarKey] = provider.id
            specifications.append(specification)
            dynamicProviderCount += 1
        }

        // A narrowed query can adopt one exact sidecar-only provider without
        // enumerating the state directory. Probe this spelling before static
        // executable aliases so `cursor-agent` can own its literal sidecar.
        if let exactRequestedProviderID,
           CmuxAgentSessionRegistry.isSafeProviderIdentifier(exactRequestedProviderID) {
            let exactSidecarURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(
                    "\(exactRequestedProviderID)-hook-sessions.json",
                    isDirectory: false
                )
            if fileManager.fileExists(atPath: exactSidecarURL.path) {
                try include(
                    AgentSessionConfiguredProvider(
                        id: exactRequestedProviderID,
                        name: exactRequestedProviderID
                    ),
                    replacesConfigured: false
                )
            }
        }

        let configURLs = agentSessionProviderConfigURLs(
            homeDirectory: homeDirectory,
            workingDirectory: processEnv["PWD"],
            fileManager: fileManager
        )
        for configURL in configURLs {
            for provider in try agentSessionConfiguredProviders(
                at: configURL,
                matchingProviderID: exactRequestedProviderID,
                fileManager: fileManager
            ) {
                try include(provider, replacesConfigured: true)
            }
        }

        let registryURL: URL
        if let explicit = processEnv["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let registryProviderIDs: [String]
        if let exactRequestedProviderID,
           CmuxAgentSessionRegistry.isSafeProviderIdentifier(exactRequestedProviderID) {
            registryProviderIDs = try registry.providerIdentifiers(
                caseInsensitiveTo: exactRequestedProviderID
            )
        } else if exactRequestedProviderID == nil {
            registryProviderIDs = try registry.providerIdentifiers()
        } else {
            registryProviderIDs = []
        }
        for providerID in registryProviderIDs {
            try include(
                AgentSessionConfiguredProvider(id: providerID, name: providerID),
                replacesConfigured: false
            )
        }
        return specifications
    }

    func agentsProviderCatalogCLIError(
        _ error: any Error,
        stateDirectory: String,
        context: AgentsValueOptionContext
    ) -> CLIError {
        let fallback = agentsStateUnavailableCLIError(
            stateDirectory: stateDirectory,
            context: context
        )
        switch error {
        case let error as CmuxAgentSessionRegistry.ProviderEnumerationLimitError:
            return CLIError(
                message: fallback.message,
                v2Code: "agent_provider_catalog_limit_exceeded",
                structuredFields: CLIErrorStructuredFields(
                    path: stateDirectory,
                    maximumCount: Int64(error.maximumCount),
                    recoveryAction: "narrow_agent_selection",
                    observedAtLeast: error.observedAtLeast
                )
            )
        case let error as AgentSessionProviderCatalogLimitError:
            return CLIError(
                message: fallback.message,
                v2Code: "agent_provider_catalog_limit_exceeded",
                structuredFields: CLIErrorStructuredFields(
                    path: stateDirectory,
                    maximumCount: Int64(error.maximumCount),
                    recoveryAction: "narrow_agent_selection",
                    observedAtLeast: error.observedAtLeast
                )
            )
        case let error as CmuxAgentSessionRegistry.UnsafeProviderIdentifierError:
            return CLIError(
                message: fallback.message,
                v2Code: "agent_provider_identifier_unsafe",
                structuredFields: CLIErrorStructuredFields(
                    provider: error.provider,
                    path: stateDirectory,
                    recoveryAction: "repair_agent_registry"
                )
            )
        case let error as AgentSessionProviderCollisionError:
            return CLIError(
                message: fallback.message,
                v2Code: "agent_provider_identifier_collision",
                structuredFields: CLIErrorStructuredFields(
                    provider: error.secondProvider,
                    conflictingProvider: error.firstProvider,
                    path: stateDirectory,
                    scope: "case_insensitive_sidecar_suffix",
                    recoveryAction: "rename_agent_provider"
                )
            )
        default:
            return fallback
        }
    }

    private func agentSessionProviderConfigURLs(
        homeDirectory: String,
        workingDirectory: String?,
        fileManager: FileManager
    ) -> [URL] {
        let home = (homeDirectory as NSString).standardizingPath
        var urls = [
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config/cmux/cmux.json", isDirectory: false),
        ]
        if let workingDirectory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty,
           let localURL = agentSessionNearestProviderConfigURL(
               startingAt: workingDirectory,
               fileManager: fileManager
           ) {
            urls.append(localURL)
        }
        var seenPaths: Set<String> = []
        return urls.filter { seenPaths.insert(($0.path as NSString).standardizingPath).inserted }
    }

    private func agentSessionNearestProviderConfigURL(
        startingAt path: String,
        fileManager: FileManager
    ) -> URL? {
        var isDirectory: ObjCBool = false
        let start = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent
        var current = (start as NSString).standardizingPath
        // Two exact probes per ancestor are predictable and avoid directory
        // enumeration. Real paths reach the filesystem root well before 64.
        for _ in 0..<64 {
            let candidates = [
                URL(fileURLWithPath: current, isDirectory: true)
                    .appendingPathComponent(".cmux/cmux.json", isDirectory: false),
                URL(fileURLWithPath: current, isDirectory: true)
                    .appendingPathComponent("cmux.json", isDirectory: false),
            ]
            if let candidate = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private func agentSessionConfiguredProviders(
        at url: URL,
        matchingProviderID: String?,
        fileManager: FileManager
    ) throws -> [AgentSessionConfiguredProvider] {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        let maximumConfigBytes = 1_024 * 1_024
        guard let data = try? handle.read(upToCount: maximumConfigBytes + 1),
              !data.isEmpty,
              data.count <= maximumConfigBytes,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let vault = root["vault"] as? [String: Any],
              let registrations = vault["agents"] as? [[String: Any]] else {
            return []
        }
        var providers: [AgentSessionConfiguredProvider] = []
        providers.reserveCapacity(
            min(registrations.count, CmuxAgentSessionRegistry.maximumProviderEnumerationCount)
        )
        var indexByProviderID: [String: Int] = [:]
        for registration in registrations {
            guard let rawID = registration["id"] as? String,
                  let rawName = registration["name"] as? String,
                  let resumeCommand = registration["resumeCommand"] as? String,
                  registration["sessionIdSource"] != nil else {
                continue
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CmuxAgentSessionRegistry.isSafeProviderIdentifier(id),
                  !name.isEmpty,
                  name.utf8.count <= 256,
                  resumeCommand.contains("{{sessionId}}")
                    || resumeCommand.contains("{{sessionPath}}") else {
                continue
            }
            if let matchingProviderID,
               id != matchingProviderID,
               agentsNormalizedAgentID(id) != agentsNormalizedAgentID(matchingProviderID) {
                continue
            }
            let provider = AgentSessionConfiguredProvider(id: id, name: name)
            if let index = indexByProviderID[id] {
                providers[index] = provider
            } else {
                indexByProviderID[id] = providers.count
                providers.append(provider)
            }
        }
        return providers
    }

    func agentTerminalObservation(
        _ observation: CmuxAgentTerminalObservation,
        matchesAnyAgentID agentIDs: Set<String>
    ) -> Bool {
        let normalizedIDs = Set(agentIDs.map(agentsNormalizedAgentID))
        let provider = agentsNormalizedAgentID(observation.sessionProviderID)
        let family = agentsNormalizedAgentID(observation.familyID)
        return normalizedIDs.contains(provider) || normalizedIDs.contains(family)
    }

    func agentTerminalObservation(
        _ observation: CmuxAgentTerminalObservation,
        matches selection: AgentSessionProviderSelection,
        requestedNormalizedID: String
    ) -> Bool {
        if let ownedProviderMatch = selection.ownedProviderMatch(for: observation) {
            return ownedProviderMatch
        }
        return agentTerminalObservation(
            observation,
            matchesAnyAgentID: Set([
                requestedNormalizedID,
                selection.providerID,
            ].compactMap { $0 })
        )
    }

    func agentTerminalObservation(
        _ observation: CmuxAgentTerminalObservation,
        canonicalizedFor selection: AgentSessionProviderSelection
    ) -> CmuxAgentTerminalObservation {
        selection.canonicalizedObservation(observation)
    }

    func agentsNormalizedAgentID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    func parseAgentsValueOption(
        _ arguments: [String],
        name: String,
        context: AgentsValueOptionContext
    ) throws -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false

        for (index, argument) in arguments.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "--" {
                pastTerminator = true
                remaining.append(argument)
                continue
            }
            if !pastTerminator, argument.hasPrefix("\(name)=") {
                let candidate = String(argument.dropFirst(name.count + 1))
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                value = candidate
                continue
            }
            if !pastTerminator, argument == name {
                guard index + 1 < arguments.count else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                let candidate = arguments[index + 1]
                guard !candidate.hasPrefix("-"),
                      !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                value = candidate
                skipNext = true
                continue
            }
            remaining.append(argument)
        }

        return (value, remaining)
    }

    private func agentsOptionRequiresValueMessage(
        name: String,
        context: AgentsValueOptionContext
    ) -> String {
        let agentMessage = switch context {
        case .agentsList, .sessionsList:
            String(
                localized: "cli.sessions.error.agentRequiresValue",
                defaultValue: "%@ list: --agent requires a value"
            )
        case .tree:
            String(
                localized: "cli.agents.tree.error.agentRequiresValue",
                defaultValue: "agents tree: --agent requires a value"
            )
        }
        let optionMessage = agentMessage.replacingOccurrences(of: "--agent", with: name)
        switch context {
        case .agentsList:
            return String(format: optionMessage, AgentsCommandInvocation.agents.rawValue)
        case .sessionsList:
            return String(format: optionMessage, AgentsCommandInvocation.sessions.rawValue)
        case .tree:
            return optionMessage
        }
    }
}
