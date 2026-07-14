import Darwin
import Foundation

struct SharedLiveAgentIndexLoader {
    typealias LoadResult = (
        index: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    )

    private let homeDirectory: String
    private let fileManager: FileManager
    private let registry: CmuxVaultAgentRegistry?
    private let registryLoader: (String, FileManager) -> CmuxVaultAgentRegistry
    private let processSnapshotProvider: () -> CmuxTopProcessSnapshot
    private let capturedAtProvider: () -> TimeInterval
    private let processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    private let injectedProcessArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)?
    private let processIdentityProvider: (Int) -> AgentPIDProcessIdentity?
    private let cachedAgentProcessValidator: CachedAgentProcessIdentityValidator

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        registry: CmuxVaultAgentRegistry? = nil,
        registryLoader: @escaping (String, FileManager) -> CmuxVaultAgentRegistry = { homeDirectory, fileManager in
            CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        },
        processSnapshotProvider: @escaping () -> CmuxTopProcessSnapshot,
        capturedAtProvider: @escaping () -> TimeInterval = {
            Date().timeIntervalSince1970
        },
        processArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)? = nil,
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        cachedAgentProcessValidator: CachedAgentProcessIdentityValidator = CachedAgentProcessIdentityValidator()
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.registry = registry
        self.registryLoader = registryLoader
        self.processSnapshotProvider = processSnapshotProvider
        self.capturedAtProvider = capturedAtProvider
        self.injectedProcessArgumentsProvider = processArgumentsProvider
        self.processArgumentsProvider = processArgumentsProvider ?? {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
        self.processIdentityProvider = processIdentityProvider
        self.cachedAgentProcessValidator = cachedAgentProcessValidator
    }

    func loadSynchronously() -> RestorableAgentSessionIndex {
        loadResultSynchronously().index
    }

    func loadResultSynchronously(
        processMetadataCaptured: @Sendable () -> Void = {}
    ) -> LoadResult {
        let processSnapshot = processSnapshotProvider()
        let capturedAt = capturedAtProvider()
        let resolvedRegistry = registry ?? registryLoader(homeDirectory, fileManager)
        var processArgumentsByPID: [Int: CmuxTopProcessArguments?] = [:]
        func cachedProcessArguments(_ processID: Int) -> CmuxTopProcessArguments? {
            if let cached = processArgumentsByPID[processID] {
                return cached
            }
            let resolved = processArgumentsProvider(processID)
            processArgumentsByPID.updateValue(resolved, forKey: processID)
            return resolved
        }
#if DEBUG
        let loadMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
            .restorableLoad,
            inputCount: processSnapshot.processesByPID.count
        )
#endif
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: resolvedRegistry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            processArgumentsProvider: injectedProcessArgumentsProvider
        )
        // Process-only session identity must be immutable before terminal teardown.
        // Hook-store and transcript loading below may continue after the runtime exits.
        processMetadataCaptured()
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: resolvedRegistry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: cachedProcessArguments,
            processIdentityProvider: processIdentityProvider
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            processArgumentsProvider: cachedProcessArguments
        )
#if DEBUG
        ProcessPerformanceMetrics.shared.operationCompleted(
            loadMetricsToken,
            outputCount: index.forkValidationEntries().count
        )
#endif
        return (
            index: index,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                bindingsByPanel: detectedBindings.mapValues(\.binding)
            ),
            liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
            processScopeFingerprint: Self.cacheValidationFingerprint(
                from: processSnapshot,
                registry: resolvedRegistry,
                fileManager: fileManager,
                processArgumentsProvider: cachedProcessArguments
            ),
            forkValidatedPanels: Self.forkValidatedPanels(
                in: index,
                processArgumentsProvider: cachedProcessArguments,
                processIdentityProvider: processIdentityProvider,
                validator: cachedAgentProcessValidator
            )
        )
    }

    static func currentCacheValidationFingerprint(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Set<String> {
        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        return cacheValidationFingerprint(
            from: snapshot,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    static func cacheValidationFingerprint(
        from snapshot: CmuxTopProcessSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Set<String> {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        var processArgumentsByPID: [Int: CmuxTopProcessArguments?] = [:]
        func cachedProcessArguments(_ processID: Int) -> CmuxTopProcessArguments? {
            if let cached = processArgumentsByPID[processID] {
                return cached
            }
            let resolved = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: processID)
            processArgumentsByPID.updateValue(resolved, forKey: processID)
            return resolved
        }
        return cacheValidationFingerprint(
            from: snapshot,
            registry: registry,
            fileManager: fileManager,
            processArgumentsProvider: cachedProcessArguments
        )
    }

    static func cacheValidationFingerprint(
        from snapshot: CmuxTopProcessSnapshot,
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> Set<String> {
        var fingerprints = processScopeFingerprint(
            from: snapshot,
            processArgumentsProvider: processArgumentsProvider
        )
        fingerprints.insert(registryFingerprint(registry, workingDirectory: ""))

        var visitedWorkingDirectories = Set<String>()
        for process in snapshot.cmuxScopedProcesses() {
            guard let environment = processArgumentsProvider(process.pid)?.environment,
                  let rawWorkingDirectory = environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"] else {
                continue
            }
            let trimmedWorkingDirectory = rawWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedWorkingDirectory.isEmpty else { continue }
            let workingDirectory = (trimmedWorkingDirectory as NSString).standardizingPath
            guard visitedWorkingDirectories.insert(workingDirectory).inserted else {
                continue
            }
            let effectiveRegistry = registry.mergingProjectConfig(
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
            fingerprints.insert(
                registryFingerprint(effectiveRegistry, workingDirectory: workingDirectory)
            )
        }

        return fingerprints
    }

    static func processScopeFingerprint(
        from snapshot: CmuxTopProcessSnapshot,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> Set<String> {
        let processes: [CmuxTopProcessInfo] = snapshot.cmuxScopedProcesses()
        var fingerprints = Set<String>()
        fingerprints.reserveCapacity(processes.count)

        for process in processes {
            let arguments: [String] = processArgumentsProvider(process.pid)?.arguments ?? []
            var components: [String] = [
                process.cmuxWorkspaceID?.uuidString ?? "",
                process.cmuxSurfaceID?.uuidString ?? "",
                String(process.pid),
                String(process.processIdentity.startSeconds),
                String(process.processIdentity.startMicroseconds),
                String(process.parentPID),
                String(process.processGroupID ?? 0),
                String(process.terminalProcessGroupID ?? 0),
                process.name,
                process.path ?? "",
                String(arguments.count)
            ]
            components.append(contentsOf: arguments)
            fingerprints.insert(encodedFingerprintComponents(components))
        }

        return fingerprints
    }

    private static func registryFingerprint(
        _ registry: CmuxVaultAgentRegistry,
        workingDirectory: String
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedRegistry = (try? encoder.encode(registry.registrations))?.base64EncodedString()
            ?? String(reflecting: registry.registrations)
        return "registry:" + encodedFingerprintComponents([workingDirectory, encodedRegistry])
    }

    private static func encodedFingerprintComponents(_ components: [String]) -> String {
        components.map { component in
            "\(component.utf8.count):\(component)"
        }.joined()
    }

    private static func forkValidatedPanels(
        in index: RestorableAgentSessionIndex,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> Set<RestorableAgentSessionIndex.PanelKey> {
        Set(index.forkValidationEntries().compactMap { key, entry in
            forkEntryIsValidForForkAvailability(
                entry,
                panelKey: key,
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: processIdentityProvider,
                validator: validator
            ) ? key : nil
        })
    }

    private static func forkEntryIsValidForForkAvailability(
        _ entry: RestorableAgentSessionIndex.Entry,
        panelKey: RestorableAgentSessionIndex.PanelKey,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> Bool {
        guard !entry.agentProcessIDs.isEmpty else { return true }
        for processID in entry.agentProcessIDs {
            guard let expectedIdentity = entry.agentProcessIdentities[processID],
                  processIdentityProvider(processID) == expectedIdentity,
                  let process = processArgumentsProvider(processID),
                  process.matchesCMUXScope(
                      workspaceId: panelKey.workspaceId,
                      surfaceId: panelKey.panelId
                  ),
                  validator.currentProcess(process, matches: entry.snapshot) else {
                return false
            }
        }
        return true
    }
}
