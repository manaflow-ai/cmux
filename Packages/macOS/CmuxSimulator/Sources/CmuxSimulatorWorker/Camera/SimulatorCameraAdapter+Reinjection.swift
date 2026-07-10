import CmuxSimulator
import Foundation

struct SimulatorCameraAutomaticReinjectionTask {
    let bundleIdentifier: String
    let task: Task<Void, Never>
}

extension SimulatorCameraAdapter {
    func prepareForIntentionalApplicationMutation(
        bundleIdentifier: String
    ) async {
        _ = advanceAutomaticReinjectionGeneration(bundleIdentifier: bundleIdentifier)
        let matchingTasks = automaticReinjectionTasks.filter {
            $0.value.bundleIdentifier == bundleIdentifier
        }
        for (_, record) in matchingTasks { record.task.cancel() }
        for (generation, record) in matchingTasks {
            await record.task.value
            automaticReinjectionTasks.removeValue(forKey: generation)
        }
        removeInjectionRecord(bundleIdentifier: bundleIdentifier)
        injectedBundleIdentifiers.remove(bundleIdentifier)
        automaticReinjectionAttempted.remove(bundleIdentifier)
        if activeTargetBundleIdentifier == bundleIdentifier {
            activeTargetBundleIdentifier = injectedBundleIdentifiers.sorted().first
            activeTargetProcessIdentifier = activeTargetBundleIdentifier.flatMap {
                injectedProcessIdentifiers[$0]
            }
        }
        guard injectedBundleIdentifiers.isEmpty else { return }
        activeConfiguration = .disabled
        if let producer { await producer.stop() }
        self.producer = nil
        surfaceRing = nil
        ownershipLock = nil
    }

    func recordInjection(
        bundleIdentifier: String,
        processIdentifier: Int32,
        resetsAutomaticFuse: Bool = true
    ) {
        removeInjectionRecord(bundleIdentifier: bundleIdentifier)
        injectedProcessIdentifiers[bundleIdentifier] = processIdentifier
        if resetsAutomaticFuse {
            automaticReinjectionAttempted.remove(bundleIdentifier)
        }
        let monitorGeneration = advanceAutomaticReinjectionGeneration(
            bundleIdentifier: bundleIdentifier
        )
        let monitor = DispatchSource.makeProcessSource(
            identifier: pid_t(processIdentifier),
            eventMask: .exit,
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleExitedInjection(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    monitorGeneration: monitorGeneration
                )
            }
        }
        injectionMonitorGenerations[bundleIdentifier] = monitorGeneration
        injectionMonitors[bundleIdentifier] = monitor
        monitor.activate()
    }

    func handleExitedInjection(
        bundleIdentifier: String,
        processIdentifier: Int32
    ) {
        guard let monitorGeneration = injectionMonitorGenerations[bundleIdentifier] else {
            return
        }
        handleExitedInjection(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            monitorGeneration: monitorGeneration
        )
    }

    func invalidateAutomaticReinjectionsSynchronously() {
        let bundleIdentifiers = Set(injectionMonitorGenerations.keys)
            .union(automaticReinjectionTasks.values.map(\.bundleIdentifier))
            .union(injectedBundleIdentifiers)
        for bundleIdentifier in bundleIdentifiers {
            _ = advanceAutomaticReinjectionGeneration(bundleIdentifier: bundleIdentifier)
        }
        for record in automaticReinjectionTasks.values {
            record.task.cancel()
        }
    }

    func cancelAndJoinAutomaticReinjections() async {
        invalidateAutomaticReinjectionsSynchronously()
        let tasks = automaticReinjectionTasks.values.map(\.task)
        for task in tasks {
            await task.value
        }
    }

    func removeInjectionRecord(bundleIdentifier: String) {
        injectionMonitors.removeValue(forKey: bundleIdentifier)?.cancel()
        injectionMonitorGenerations.removeValue(forKey: bundleIdentifier)
        injectedProcessIdentifiers.removeValue(forKey: bundleIdentifier)
    }

    func cancelInjectionMonitors() {
        let monitors = injectionMonitors.values
        injectionMonitors.removeAll()
        injectionMonitorGenerations.removeAll()
        for monitor in monitors { monitor.cancel() }
    }

    private func handleExitedInjection(
        bundleIdentifier: String,
        processIdentifier: Int32,
        monitorGeneration: UInt64
    ) {
        guard automaticReinjectionGenerations[bundleIdentifier] == monitorGeneration,
              !activeConfiguration.isDisabled,
              simulatorCameraShouldReinstateExitedTarget(
                  configuredBundleIdentifiers: injectedBundleIdentifiers,
                  processIdentifiers: injectedProcessIdentifiers,
                  bundleIdentifier: bundleIdentifier,
                  exitedProcessIdentifier: processIdentifier
              ) else { return }

        let taskGeneration = advanceAutomaticReinjectionGeneration(
            bundleIdentifier: bundleIdentifier
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reinstateExitedInjection(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                taskGeneration: taskGeneration
            )
            self.automaticReinjectionTasks.removeValue(forKey: taskGeneration)
        }
        automaticReinjectionTasks[taskGeneration] = SimulatorCameraAutomaticReinjectionTask(
            bundleIdentifier: bundleIdentifier,
            task: task
        )
    }

    private func reinstateExitedInjection(
        bundleIdentifier: String,
        processIdentifier: Int32,
        taskGeneration: UInt64
    ) async {
        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration
        ), simulatorCameraShouldReinstateExitedTarget(
            configuredBundleIdentifiers: injectedBundleIdentifiers,
            processIdentifiers: injectedProcessIdentifiers,
            bundleIdentifier: bundleIdentifier,
            exitedProcessIdentifier: processIdentifier
        ) else { return }

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration
        ) else { return }
        removeInjectionRecord(bundleIdentifier: bundleIdentifier)

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration
        ) else { return }
        if activeTargetBundleIdentifier == bundleIdentifier {
            activeTargetProcessIdentifier = nil
        }

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration
        ), automaticReinjectionAttempted.insert(bundleIdentifier).inserted,
              let expectedDeviceIdentifier = deviceIdentifier,
              let ring = surfaceRing else { return }
        let expectedSharedMemoryName = ring.sharedMemoryName

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration,
            deviceIdentifier: expectedDeviceIdentifier,
            sharedMemoryName: expectedSharedMemoryName
        ), let libraryURL = try? await compiledLibraryOperation() else { return }

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration,
            deviceIdentifier: expectedDeviceIdentifier,
            sharedMemoryName: expectedSharedMemoryName
        ) else { return }
        let launch: SimulatorSubprocessResult
        do {
            launch = try await mutationGate.withLocks([
                .tcc(deviceIdentifier: expectedDeviceIdentifier),
                .application(
                    deviceIdentifier: expectedDeviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                ),
            ]) {
                guard automaticReinjectionIsCurrent(
                    bundleIdentifier: bundleIdentifier,
                    generation: taskGeneration,
                    deviceIdentifier: expectedDeviceIdentifier,
                    sharedMemoryName: expectedSharedMemoryName
                ) else { throw CancellationError() }
                applicationMutationWillCommit(bundleIdentifier)
                try await cameraPermission.grant(
                    deviceIdentifier: expectedDeviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                )
                guard automaticReinjectionIsCurrent(
                    bundleIdentifier: bundleIdentifier,
                    generation: taskGeneration,
                    deviceIdentifier: expectedDeviceIdentifier,
                    sharedMemoryName: expectedSharedMemoryName
                ) else { throw CancellationError() }
                _ = try? await runSimctl([
                    "terminate", expectedDeviceIdentifier, bundleIdentifier,
                ])
                guard automaticReinjectionIsCurrent(
                    bundleIdentifier: bundleIdentifier,
                    generation: taskGeneration,
                    deviceIdentifier: expectedDeviceIdentifier,
                    sharedMemoryName: expectedSharedMemoryName
                ) else { throw CancellationError() }
                return try await runSimctl(
                    ["launch", expectedDeviceIdentifier, bundleIdentifier],
                    environment: [
                        "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": libraryURL.path,
                        "SIMCTL_CHILD_SIMCAM_SHM_NAME": expectedSharedMemoryName,
                    ]
                )
            }
        } catch {
            return
        }

        guard automaticReinjectionIsCurrent(
            bundleIdentifier: bundleIdentifier,
            generation: taskGeneration,
            deviceIdentifier: expectedDeviceIdentifier,
            sharedMemoryName: expectedSharedMemoryName
        ), let replacementPID = simulatorCameraProcessIdentifier(
            fromLaunchOutput: launch.standardOutput
        )
        else { return }

        recordInjection(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: replacementPID,
            resetsAutomaticFuse: false
        )
        if activeTargetBundleIdentifier == bundleIdentifier {
            activeTargetProcessIdentifier = replacementPID
        }
    }

    private func automaticReinjectionIsCurrent(
        bundleIdentifier: String,
        generation: UInt64,
        deviceIdentifier expectedDeviceIdentifier: String? = nil,
        sharedMemoryName expectedSharedMemoryName: String? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              automaticReinjectionGenerations[bundleIdentifier] == generation,
              injectedBundleIdentifiers.contains(bundleIdentifier),
              !activeConfiguration.isDisabled else { return false }
        if let expectedDeviceIdentifier,
           deviceIdentifier != expectedDeviceIdentifier { return false }
        if let expectedSharedMemoryName,
           surfaceRing?.sharedMemoryName != expectedSharedMemoryName { return false }
        return true
    }

    private func advanceAutomaticReinjectionGeneration(
        bundleIdentifier: String
    ) -> UInt64 {
        nextAutomaticReinjectionGeneration &+= 1
        automaticReinjectionGenerations[bundleIdentifier] = nextAutomaticReinjectionGeneration
        return nextAutomaticReinjectionGeneration
    }
}
