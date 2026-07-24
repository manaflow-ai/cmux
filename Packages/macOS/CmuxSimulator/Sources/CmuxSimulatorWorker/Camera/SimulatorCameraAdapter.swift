import CmuxSimulator
import Foundation

/// Worker-owned synthetic-camera lifecycle.
///
/// The injected library is compiled from bundled serve-sim Apache-2 sources,
/// loaded only into the selected simulated app, and fed by IOSurfaces owned by
/// this worker. No swizzle or camera object enters the cmux process.
@MainActor
final class SimulatorCameraAdapter {
    typealias CompiledLibraryOperation = @Sendable () async throws -> URL
    typealias SimctlOperation = @Sendable (
        [String],
        [String: String]
    ) async throws -> SimulatorSubprocessResult
    typealias TargetResolvedOperation = @MainActor @Sendable (String) async throws -> Void
    typealias OperationIsCurrent = @MainActor @Sendable () -> Bool
    typealias ApplicationMutationWillCommit = @MainActor @Sendable (String) -> Void
    typealias HostCameraDevicesOperation = @MainActor @Sendable () -> [SimulatorHostCameraDevice]

    let compiledLibraryOperation: CompiledLibraryOperation
    let simctlOperation: SimctlOperation
    let cameraPermission: SimulatorCameraPermissionAdapter
    let mutationGate: SimulatorMutationGate
    let applicationMutationWillCommit: ApplicationMutationWillCommit
    let hostCameraDevicesOperation: HostCameraDevicesOperation
    let fileManager: FileManager
    let sharedMemoryToken: String?
    var deviceIdentifier: String?
    var surfaceRing: SimulatorCameraSurfaceRing?
    var ownershipLock: SimulatorCameraOwnershipLock?
    var producer: SimulatorCameraFrameProducer?
    var injectedBundleIdentifiers: Set<String> = []
    var injectedProcessIdentifiers: [String: Int32] = [:]
    var injectionMonitors: [String: DispatchSourceProcess] = [:]
    var injectionMonitorGenerations: [String: UInt64] = [:]
    var automaticReinjectionAttempted: Set<String> = []
    var automaticReinjectionGenerations: [String: UInt64] = [:]
    var automaticReinjectionTasks: [UInt64: SimulatorCameraAutomaticReinjectionTask] = [:]
    var nextAutomaticReinjectionGeneration: UInt64 = 0
    var activeTargetBundleIdentifier: String?
    var activeTargetProcessIdentifier: Int32?
    var activeConfiguration: SimulatorCameraConfiguration = .disabled
    var mirrorMode: SimulatorCameraMirrorMode = .auto

    init(
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        fileManager: FileManager = FileManager(),
        sharedMemoryToken: String? = ProcessInfo.processInfo.environment[
            SimulatorCameraSharedMemory.tokenEnvironmentKey
        ],
        cameraPermission: SimulatorCameraPermissionAdapter? = nil,
        compiledLibrary: CompiledLibraryOperation? = nil,
        simctl: SimctlOperation? = nil,
        mutationGate: SimulatorMutationGate = SimulatorMutationGate(),
        applicationMutationWillCommit: @escaping ApplicationMutationWillCommit = { _ in },
        hostCameraDevices: @escaping HostCameraDevicesOperation = simulatorAvailableHostCameras
    ) {
        let compiler = SimulatorCameraInjectorCompiler(
            subprocessRunner: subprocessRunner,
            fileSystem: SimulatorCameraFileSystem(manager: fileManager)
        )
        compiledLibraryOperation = compiledLibrary ?? {
            try await compiler.compiledLibrary()
        }
        simctlOperation = simctl ?? { arguments, environment in
            try await subprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl"] + arguments,
                environment: environment
            )
        }
        self.cameraPermission = cameraPermission
            ?? SimulatorCameraPermissionAdapter(subprocessRunner: subprocessRunner)
        self.mutationGate = mutationGate
        self.applicationMutationWillCommit = applicationMutationWillCommit
        hostCameraDevicesOperation = hostCameraDevices
        self.fileManager = fileManager
        self.sharedMemoryToken = sharedMemoryToken
    }

    var isAvailable: Bool {
        Bundle.module.resourceURL.map {
            fileManager.fileExists(
                atPath: $0.appendingPathComponent("CameraInjector/SimCameraInjector.m.txt").path
            )
        } ?? false
    }

    func attach(deviceIdentifier: String) {
        if self.deviceIdentifier != deviceIdentifier {
            activeConfiguration = .disabled
            invalidateAutomaticReinjectionsSynchronously()
            cancelInjectionMonitors()
            if let producer { Task { await producer.stop() } }
            producer = nil
            surfaceRing = nil
            ownershipLock = nil
            injectedBundleIdentifiers.removeAll()
            injectedProcessIdentifiers.removeAll()
            automaticReinjectionAttempted.removeAll()
            activeTargetBundleIdentifier = nil
            activeTargetProcessIdentifier = nil
            activeConfiguration = .disabled
            mirrorMode = .auto
        }
        self.deviceIdentifier = deviceIdentifier
    }

    func configure(
        _ configuration: SimulatorCameraConfiguration,
        inferredApplication: SimulatorApplicationInfo?,
        targetResolved: TargetResolvedOperation = { _ in },
        operationIsCurrent: OperationIsCurrent = { !Task.isCancelled }
    ) async throws -> SimulatorApplicationInfo? {
        func requireCurrentOperation() throws {
            guard operationIsCurrent() else { throw CancellationError() }
        }
        try requireCurrentOperation()
        guard let deviceIdentifier else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Synthetic camera injection requires an attached Simulator."
            )
        }
        if configuration.isDisabled {
            try await disable(deviceIdentifier: deviceIdentifier)
            return nil
        }
        guard isAvailable else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The bundled synthetic-camera injector sources are unavailable."
            )
        }
        let acquiredOwnership = ownershipLock == nil
        if acquiredOwnership {
            ownershipLock = try SimulatorCameraOwnershipLock(
                deviceIdentifier: deviceIdentifier
            )
        }
        var configurationSucceeded = false
        defer {
            if acquiredOwnership && !configurationSucceeded && injectedBundleIdentifiers.isEmpty {
                ownershipLock = nil
            }
        }

        let explicitBundleIdentifier = configuration.targetBundleIdentifier
        let bundleIdentifier = explicitBundleIdentifier ?? inferredApplication?.bundleIdentifier
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Bring one app to the foreground or select an explicit camera target."
            )
        }
        try await validateInstalledApp(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try requireCurrentOperation()
        let hasLiveInjection = await injectionIsLive(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try requireCurrentOperation()
        if !hasLiveInjection {
            injectedBundleIdentifiers.remove(bundleIdentifier)
            removeInjectionRecord(bundleIdentifier: bundleIdentifier)
            if activeTargetBundleIdentifier == bundleIdentifier {
                activeTargetBundleIdentifier = nil
                activeTargetProcessIdentifier = nil
            }
        }
        let requiresInjection = !hasLiveInjection
        let libraryURL = requiresInjection ? try await compiledLibraryOperation() : nil
        try requireCurrentOperation()

        let previousConfiguration = activeConfiguration
        let hadSurfaceRing = surfaceRing != nil
        var applicationMutationCommitted = false
        let ring: SimulatorCameraSurfaceRing
        if let surfaceRing {
            ring = surfaceRing
        } else {
            ring = try SimulatorCameraSurfaceRing(
                deviceIdentifier: deviceIdentifier,
                sharedMemoryToken: sharedMemoryToken
            )
            surfaceRing = ring
        }
        let producer: SimulatorCameraFrameProducer
        if let existing = self.producer {
            producer = existing
        } else {
            producer = SimulatorCameraFrameProducer(surfaceRing: ring)
            self.producer = producer
        }
        do {
            applyMirrorMode(to: ring)
            try await producer.configure(configuration)
            try requireCurrentOperation()
            try await targetResolved(bundleIdentifier)
            try requireCurrentOperation()

            if !requiresInjection {
                activeTargetBundleIdentifier = bundleIdentifier
                activeTargetProcessIdentifier = injectedProcessIdentifiers[bundleIdentifier]
                activeConfiguration = configuration
                configurationSucceeded = true
                return inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication
                    : SimulatorApplicationInfo(
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: nil,
                        name: nil,
                        version: nil,
                        build: nil,
                        minimumOSVersion: nil,
                        isReactNative: false
                    )
            }

            guard let libraryURL else {
                throw SimulatorWorkerFailure.frameworkUnavailable(
                    "The synthetic-camera injector library is unavailable."
                )
            }
            let launch = try await mutationGate.withLocks([
                .tcc(deviceIdentifier: deviceIdentifier),
                .application(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                ),
            ]) {
                try requireCurrentOperation()
                applicationMutationWillCommit(bundleIdentifier)
                try await cameraPermission.grant(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                )
                try requireCurrentOperation()
                _ = try? await runSimctl([
                    "terminate", deviceIdentifier, bundleIdentifier,
                ])
                applicationMutationCommitted = true
                try requireCurrentOperation()
                return try await runSimctl(
                    ["launch", deviceIdentifier, bundleIdentifier],
                    environment: [
                        "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": libraryURL.path,
                        "SIMCTL_CHILD_SIMCAM_SHM_NAME": ring.sharedMemoryName,
                    ]
                )
            }
            try requireCurrentOperation()
            injectedBundleIdentifiers.insert(bundleIdentifier)
            activeTargetBundleIdentifier = bundleIdentifier
            activeConfiguration = configuration
            let processIdentifier = simulatorCameraProcessIdentifier(
                fromLaunchOutput: launch.standardOutput
            )
            activeTargetProcessIdentifier = processIdentifier
            if let processIdentifier {
                recordInjection(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
            }
            configurationSucceeded = true
            return SimulatorApplicationInfo(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                name: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.name : nil,
                version: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.version : nil,
                build: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.build : nil,
                minimumOSVersion: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.minimumOSVersion : nil,
                isReactNative: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.isReactNative ?? false : false,
                executable: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.executable : nil,
                bundlePath: inferredApplication?.bundleIdentifier == bundleIdentifier
                    ? inferredApplication?.bundlePath : nil
            )
        } catch {
            applyMirrorMode(to: ring)
            if previousConfiguration.isDisabled {
                await producer.stop()
                self.producer = nil
                if !hadSurfaceRing {
                    surfaceRing = nil
                }
            } else {
                try? await producer.configure(previousConfiguration)
            }
            if requiresInjection {
                injectedBundleIdentifiers.remove(bundleIdentifier)
                removeInjectionRecord(bundleIdentifier: bundleIdentifier)
                if activeTargetBundleIdentifier == bundleIdentifier {
                    activeTargetBundleIdentifier = nil
                    activeTargetProcessIdentifier = nil
                }
                if applicationMutationCommitted {
                    _ = try? await mutationGate.withLocks([
                        .application(
                            deviceIdentifier: deviceIdentifier,
                            bundleIdentifier: bundleIdentifier
                        ),
                    ]) {
                        applicationMutationWillCommit(bundleIdentifier)
                        _ = try? await runSimctl([
                            "terminate", deviceIdentifier, bundleIdentifier,
                        ])
                        return try await runSimctl([
                            "launch", deviceIdentifier, bundleIdentifier,
                        ])
                    }
                }
            }
            throw error
        }
    }

    func stop() {
        activeConfiguration = .disabled
        invalidateAutomaticReinjectionsSynchronously()
        cancelInjectionMonitors()
        if let producer { Task { await producer.stop() } }
        producer = nil
        surfaceRing = nil
        ownershipLock = nil
    }

    func switchSource(_ configuration: SimulatorCameraConfiguration) async throws {
        guard simulatorCameraCanSwitchSource(
            configuration,
            configuredTargetCount: injectedBundleIdentifiers.count,
            hasProducer: producer != nil
        ), let producer else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.cameraSourceInactive",
                    defaultValue: "A synthetic-camera source can only be switched while a camera session is active."
                )
            )
        }
        try await producer.configure(configuration)
        activeConfiguration = configuration
    }

    func shutdown() async {
        guard let deviceIdentifier else {
            stop()
            await cancelAndJoinAutomaticReinjections()
            return
        }
        try? await disable(deviceIdentifier: deviceIdentifier)
    }

    func detachFromUnavailableDevice() {
        stop()
        injectedBundleIdentifiers.removeAll()
        injectedProcessIdentifiers.removeAll()
        automaticReinjectionAttempted.removeAll()
        activeTargetBundleIdentifier = nil
        activeTargetProcessIdentifier = nil
        deviceIdentifier = nil
        ownershipLock = nil
        mirrorMode = .auto
    }

    private func disable(deviceIdentifier: String) async throws {
        defer { ownershipLock = nil }
        activeConfiguration = .disabled
        invalidateAutomaticReinjectionsSynchronously()
        cancelInjectionMonitors()
        if let producer { await producer.stop() }
        producer = nil
        surfaceRing = nil
        await cancelAndJoinAutomaticReinjections()
        let bundles = injectedBundleIdentifiers.sorted()
        injectedBundleIdentifiers.removeAll()
        injectedProcessIdentifiers.removeAll()
        automaticReinjectionAttempted.removeAll()
        activeTargetBundleIdentifier = nil
        activeTargetProcessIdentifier = nil
        var firstFailure: Error?
        for bundleIdentifier in bundles {
            do {
                try await mutationGate.withLocks([
                    .application(
                        deviceIdentifier: deviceIdentifier,
                        bundleIdentifier: bundleIdentifier
                    ),
                ]) {
                    applicationMutationWillCommit(bundleIdentifier)
                    _ = try? await runSimctl([
                        "terminate", deviceIdentifier, bundleIdentifier,
                    ])
                    _ = try await runSimctl([
                        "launch", deviceIdentifier, bundleIdentifier,
                    ])
                }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func validateInstalledApp(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws {
        let result = try await runSimctl(["listapps", deviceIdentifier])
        guard simulatorCameraIsInstalledUserApplication(
            bundleIdentifier: bundleIdentifier,
            listApplicationsOutput: result.standardOutput
        ) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Synthetic camera injection is restricted to installed user applications."
            )
        }
    }

    private func injectionIsLive(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async -> Bool {
        guard injectedBundleIdentifiers.contains(bundleIdentifier),
              let processIdentifier = injectedProcessIdentifiers[bundleIdentifier],
              surfaceRing?.injectorAttachments().contains(where: {
                  $0.processIdentifier == processIdentifier && $0.isAttached
              }) == true
        else {
            return false
        }
        guard (try? await runSimctl([
            "spawn", deviceIdentifier, "/bin/kill", "-0", String(processIdentifier),
        ])) != nil else {
            return false
        }
        activeTargetProcessIdentifier = processIdentifier
        return true
    }

    func runSimctl(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> SimulatorSubprocessResult {
        let result = try await simctlOperation(arguments, environment)
        guard result.status == 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "simctl \(arguments.first ?? "camera") failed with status \(result.status)."
                    : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

}
