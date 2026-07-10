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

    let compiledLibraryOperation: CompiledLibraryOperation
    let simctlOperation: SimctlOperation
    let cameraPermission: SimulatorCameraPermissionAdapter
    var deviceIdentifier: String?
    var surfaceRing: SimulatorCameraSurfaceRing?
    private var ownershipLock: SimulatorCameraOwnershipLock?
    private var producer: SimulatorCameraFrameProducer?
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
    private var mirrorMode: SimulatorCameraMirrorMode = .auto

    init(
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        cameraPermission: SimulatorCameraPermissionAdapter? = nil,
        compiledLibrary: CompiledLibraryOperation? = nil,
        simctl: SimctlOperation? = nil
    ) {
        let compiler = SimulatorCameraInjectorCompiler(subprocessRunner: subprocessRunner)
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
    }

    var isAvailable: Bool {
        Bundle.module.resourceURL.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("CameraInjector/SimCameraInjector.m.txt").path
            )
        } ?? false
    }

    func attach(deviceIdentifier: String) {
        if self.deviceIdentifier != deviceIdentifier {
            activeConfiguration = .disabled
            invalidateAutomaticReinjectionsSynchronously()
            cancelInjectionMonitors()
            producer?.stop()
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
        inferredApplication: SimulatorApplicationInfo?
    ) async throws -> SimulatorApplicationInfo? {
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
            ownershipLock = try SimulatorCameraOwnershipLock.acquire(
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
        let hasLiveInjection = await injectionIsLive(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
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

        let previousConfiguration = activeConfiguration
        let hadSurfaceRing = surfaceRing != nil
        let ring: SimulatorCameraSurfaceRing
        if let surfaceRing {
            ring = surfaceRing
        } else {
            ring = try SimulatorCameraSurfaceRing(deviceIdentifier: deviceIdentifier)
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

            try await cameraPermission.grant(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            _ = try? await runSimctl([
                "terminate", deviceIdentifier, bundleIdentifier,
            ])
            guard let libraryURL else {
                throw SimulatorWorkerFailure.frameworkUnavailable(
                    "The synthetic-camera injector library is unavailable."
                )
            }
            let launch = try await runSimctl(
                ["launch", deviceIdentifier, bundleIdentifier],
                environment: [
                    "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": libraryURL.path,
                    "SIMCTL_CHILD_SIMCAM_SHM_NAME": ring.sharedMemoryName,
                ]
            )
            injectedBundleIdentifiers.insert(bundleIdentifier)
            activeTargetBundleIdentifier = bundleIdentifier
            activeConfiguration = configuration
            let processIdentifier = Self.processIdentifier(fromLaunchOutput: launch.standardOutput)
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
                producer.stop()
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
                _ = try? await runSimctl(["launch", deviceIdentifier, bundleIdentifier])
            }
            throw error
        }
    }

    func stop() {
        activeConfiguration = .disabled
        invalidateAutomaticReinjectionsSynchronously()
        cancelInjectionMonitors()
        producer?.stop()
        producer = nil
        surfaceRing = nil
        ownershipLock = nil
    }

    func switchSource(_ configuration: SimulatorCameraConfiguration) async throws {
        guard Self.canSwitchSource(
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

    func setMirrorMode(_ mode: SimulatorCameraMirrorMode) -> Bool {
        mirrorMode = mode
        guard let surfaceRing else { return true }
        applyMirrorMode(to: surfaceRing)
        return true
    }

    func status() -> SimulatorCameraStatus {
        let attachmentPIDs = Set(
            surfaceRing?.injectorAttachments()
                .filter(\.isAttached)
                .compactMap(\.processIdentifier) ?? []
        )
        let liveBundles = injectedProcessIdentifiers.compactMap { bundle, processIdentifier in
            attachmentPIDs.contains(processIdentifier) ? bundle : nil
        }.sorted()
        let targets = Self.targetStatuses(
            configuredBundleIdentifiers: injectedBundleIdentifiers,
            processIdentifiers: injectedProcessIdentifiers,
            attachedProcessIdentifiers: attachmentPIDs
        )
        let activePID = activeTargetBundleIdentifier.flatMap {
            injectedProcessIdentifiers[$0]
        } ?? activeTargetProcessIdentifier
        let processMatches = activePID.map(attachmentPIDs.contains) == true
        let targetIsAttached = activeTargetBundleIdentifier != nil
            && processMatches
        let targetIsAlive = activeTargetBundleIdentifier.flatMap {
            injectedProcessIdentifiers[$0]
        } != nil
        return SimulatorCameraStatus(
            configuration: activeConfiguration,
            mirrorMode: mirrorMode,
            injectedBundleIdentifiers: liveBundles,
            targetBundleIdentifier: activeTargetBundleIdentifier,
            targetProcessIdentifier: activePID,
            targetIsAlive: targetIsAlive,
            targetIsAttached: targetIsAttached,
            targets: targets,
            hostCameras: SimulatorCameraFrameProducer.availableHostCameras()
        )
    }

    private func disable(deviceIdentifier: String) async throws {
        defer { ownershipLock = nil }
        activeConfiguration = .disabled
        invalidateAutomaticReinjectionsSynchronously()
        cancelInjectionMonitors()
        producer?.stop()
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
            _ = try? await runSimctl(["terminate", deviceIdentifier, bundleIdentifier])
            do {
                _ = try await runSimctl(["launch", deviceIdentifier, bundleIdentifier])
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
        guard Self.isInstalledUserApplication(
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

    private func applyMirrorMode(to ring: SimulatorCameraSurfaceRing) {
        switch mirrorMode {
        case .auto:
            ring.setMirrored(nil)
        case .on:
            ring.setMirrored(true)
        case .off:
            ring.setMirrored(false)
        }
    }

}
