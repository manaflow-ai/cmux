import CmuxSimulator
import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorWorker

// The camera fixtures intentionally exercise the same process-global device lock.
@Suite("Simulator camera containment", .serialized)
struct SimulatorCameraAdapterTests {
    @Test("Camera status starts disabled and mirror changes hot-swap")
    @MainActor
    func cameraStatus() {
        let adapter = SimulatorCameraAdapter()

        #expect(adapter.status().configuration == .disabled)
        #expect(adapter.status().mirrorMode == .auto)
        #expect(!adapter.status().targetIsAlive)
        #expect(!adapter.status().targetIsAttached)
        #expect(adapter.setMirrorMode(.on))
        #expect(adapter.status().mirrorMode == .on)
        adapter.attach(deviceIdentifier: "DEVICE")
        adapter.detachFromUnavailableDevice()
        #expect(adapter.status().configuration == .disabled)
        #expect(adapter.status().mirrorMode == .auto)
    }

    @Test("Injector heartbeat expires instead of reporting a stale attachment")
    func heartbeatFreshness() {
        #expect(simulatorCameraAttachmentIsFresh(
            attached: true,
            processIdentifier: 42,
            heartbeatNanoseconds: 1_000,
            nowNanoseconds: 2_000,
            maximumAgeNanoseconds: 1_000
        ))
        #expect(!simulatorCameraAttachmentIsFresh(
            attached: true,
            processIdentifier: 42,
            heartbeatNanoseconds: 1_000,
            nowNanoseconds: 2_001,
            maximumAgeNanoseconds: 1_000
        ))
        #expect(!simulatorCameraAttachmentIsFresh(
            attached: false,
            processIdentifier: 42,
            heartbeatNanoseconds: 1_000,
            nowNanoseconds: 1_000,
            maximumAgeNanoseconds: 1_000
        ))
    }

    @Test("Stale injector slots remain reusable beyond one full table of app churn")
    func attachmentSlotReclamation() throws {
        var slots = Array(repeating: SimulatorCameraAttachmentSlotSnapshot(
            processIdentifier: 0,
            heartbeatNanoseconds: 0
        ), count: 16)
        for processIdentifier in UInt32(1)...64 {
            let now = UInt64(processIdentifier) * 10_000
            let index = try #require(simulatorCameraAttachmentSlotIndex(
                slots: slots,
                processIdentifier: processIdentifier,
                nowNanoseconds: now,
                maximumAgeNanoseconds: 1_000
            ))
            slots[index] = SimulatorCameraAttachmentSlotSnapshot(
                processIdentifier: processIdentifier,
                heartbeatNanoseconds: now
            )
        }
        #expect(slots.contains { $0.processIdentifier == 64 })
    }

    @Test("Only one worker process owner can hold a device camera session")
    func exclusiveDeviceOwnership() throws {
        var first: SimulatorCameraOwnershipLock? = try .init(deviceIdentifier: "DEVICE-LOCK")
        #expect(throws: SimulatorWorkerFailure.self) {
            _ = try SimulatorCameraOwnershipLock(deviceIdentifier: "device-lock")
        }
        first = nil
        let reacquired = try SimulatorCameraOwnershipLock(
            deviceIdentifier: "DEVICE-LOCK"
        )
        _ = reacquired
        _ = first
    }

    @Test("Multiple injected targets retain independent attachment state")
    func multipleTargetStatus() {
        let statuses = simulatorCameraTargetStatuses(
            configuredBundleIdentifiers: ["com.example.a", "com.example.b"],
            processIdentifiers: ["com.example.a": 10, "com.example.b": 20],
            attachedProcessIdentifiers: [10, 20]
        )

        #expect(statuses.map(\.bundleIdentifier) == ["com.example.a", "com.example.b"])
        #expect(statuses.allSatisfy { $0.isAlive })
        #expect(statuses.allSatisfy { $0.isAttached })
    }

    @Test("A configured target without a replacement PID reports dead and detached")
    func staleTargetStatus() throws {
        let statuses = simulatorCameraTargetStatuses(
            configuredBundleIdentifiers: ["com.example.a"],
            processIdentifiers: [:],
            attachedProcessIdentifiers: []
        )
        let status = try #require(statuses.first)
        #expect(status.processIdentifier == nil)
        #expect(!status.isAlive)
        #expect(!status.isAttached)
    }

    @Test("Source-only camera switching rejects disabled, targeted, and inactive sessions")
    func sourceSwitchValidation() {
        #expect(!simulatorCameraCanSwitchSource(
            .disabled,
            configuredTargetCount: 2,
            hasProducer: true
        ))
        #expect(!simulatorCameraCanSwitchSource(
            .targeted(bundleIdentifier: "com.example.a", source: .placeholder),
            configuredTargetCount: 2,
            hasProducer: true
        ))
        #expect(!simulatorCameraCanSwitchSource(
            .placeholder,
            configuredTargetCount: 0,
            hasProducer: false
        ))
        #expect(simulatorCameraCanSwitchSource(
            .placeholder,
            configuredTargetCount: 2,
            hasProducer: true
        ))
    }

    @Test("Only the matching configured crashed PID triggers reinjection")
    func automaticReinjectionPolicy() {
        let configured: Set<String> = ["com.example.a", "com.example.b"]
        let processes = ["com.example.a": Int32(10), "com.example.b": Int32(20)]
        #expect(simulatorCameraShouldReinstateExitedTarget(
            configuredBundleIdentifiers: configured,
            processIdentifiers: processes,
            bundleIdentifier: "com.example.a",
            exitedProcessIdentifier: 10
        ))
        #expect(!simulatorCameraShouldReinstateExitedTarget(
            configuredBundleIdentifiers: configured,
            processIdentifiers: processes,
            bundleIdentifier: "com.example.a",
            exitedProcessIdentifier: 11
        ))
        #expect(simulatorCameraShouldAutomaticallyReinstateExitedTarget(
            configuredBundleIdentifiers: configured,
            processIdentifiers: processes,
            automaticReinjectionAttempted: [],
            bundleIdentifier: "com.example.a",
            exitedProcessIdentifier: 10
        ))
        #expect(!simulatorCameraShouldAutomaticallyReinstateExitedTarget(
            configuredBundleIdentifiers: configured,
            processIdentifiers: processes,
            automaticReinjectionAttempted: ["com.example.a"],
            bundleIdentifier: "com.example.a",
            exitedProcessIdentifier: 10
        ))
    }

    @Test("Disabling joins a suspended reinjection without a stale injected launch")
    @MainActor
    func disablingSuspendedReinjection() async throws {
        let bundleIdentifier = "com.example.CameraFixture"
        let processIdentifier = Int32(getpid())
        let compileGate = CameraReinjectionCompileGate(
            libraryURL: URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib")
        )
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        let permission = SimulatorCameraPermissionAdapter { _, _, _, _ in }
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: UUID().uuidString,
            cameraPermission: permission,
            compiledLibrary: { await compileGate.compiledLibrary() },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: "DEVICE-\(UUID().uuidString)")
        _ = try await adapter.configure(
            .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
            inferredApplication: nil
        )

        adapter.handleExitedInjection(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        await compileGate.waitUntilSuspended()
        #expect(adapter.automaticReinjectionTasks.count == 1)

        _ = try await adapter.configure(.disabled, inferredApplication: nil)
        await compileGate.waitUntilCancelled()

        #expect(adapter.automaticReinjectionTasks.isEmpty)
        #expect(await simctl.injectedLaunchCount == 1)
        let status = adapter.status()
        #expect(status.configuration == .disabled)
        #expect(status.targetProcessIdentifier == nil)
        #expect(status.targets.isEmpty)
    }

    @Test("Synchronous lifecycle transitions invalidate suspended reinjections")
    @MainActor
    func synchronousReinjectionInvalidation() async throws {
        for transition in ["stop", "detach", "device-switch"] {
            let fixture = try await makeSuspendedCameraReinjectionFixture()
            switch transition {
            case "stop":
                fixture.adapter.stop()
            case "detach":
                fixture.adapter.detachFromUnavailableDevice()
            default:
                fixture.adapter.attach(deviceIdentifier: "DEVICE-\(UUID().uuidString)")
            }
            await fixture.compileGate.waitUntilCancelled()
            await fixture.adapter.shutdown()

            #expect(fixture.adapter.automaticReinjectionTasks.isEmpty, "\(transition)")
            #expect(await fixture.simctl.injectedLaunchCount == 1, "\(transition)")
            let status = fixture.adapter.status()
            #expect(status.configuration == .disabled, "\(transition)")
            #expect(status.targetProcessIdentifier == nil, "\(transition)")
            #expect(status.targets.isEmpty, "\(transition)")
        }
    }

    @Test("A detached camera operation performs no stale external mutation")
    @MainActor
    func detachedConfigurationDoesNotMutateSimulator() async throws {
        let bundleIdentifier = "com.example.CameraFixture"
        let compileGate = CameraConfigurationCompileGate(
            libraryURL: URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib")
        )
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(getpid())
        )
        let permission = CameraPermissionRecorder()
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: UUID().uuidString,
            cameraPermission: SimulatorCameraPermissionAdapter {
                device, action, service, bundle in
                await permission.record(
                    device: device,
                    action: action,
                    service: service,
                    bundle: bundle
                )
            },
            compiledLibrary: { await compileGate.compile() },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: "DEVICE")
        var operationIsCurrent = true
        let operation = Task { @MainActor in
            try await adapter.configure(
                .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
                inferredApplication: nil,
                operationIsCurrent: { operationIsCurrent }
            )
        }
        await compileGate.waitUntilStarted()

        operationIsCurrent = false
        await compileGate.release()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await permission.mutation == nil)
        #expect(await simctl.lifecycleMutationCount == 0)
        adapter.detachFromUnavailableDevice()
    }

    @Test("Cancellation after an injected launch rolls the app back cleanly")
    @MainActor
    func committedInjectionCancellationRollsBack() async throws {
        let suffix = UUID().uuidString
        let bundleIdentifier = "com.example.CameraFixtureCommitted.\(suffix)"
        let deviceIdentifier = "DEVICE"
        var operationIsCurrent = true
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(getpid()),
            injectedLaunchDidComplete: { operationIsCurrent = false }
        )
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: "committed-\(suffix)",
            cameraPermission: SimulatorCameraPermissionAdapter { _, _, _, _ in },
            compiledLibrary: { URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib") },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: deviceIdentifier)
        await #expect(throws: CancellationError.self) {
            try await adapter.configure(
                .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
                inferredApplication: nil,
                operationIsCurrent: { operationIsCurrent }
            )
        }
        #expect(await simctl.injectedLaunchCount == 1)
        #expect(await simctl.cleanLaunchCount == 1)
        #expect(await simctl.terminateCount == 2)
        #expect(!adapter.status().injectedBundleIdentifiers.contains(bundleIdentifier))
        adapter.detachFromUnavailableDevice()
    }

    @Test("Camera failure before app mutation does not launch the target")
    @MainActor
    func preMutationFailureDoesNotLaunch() async throws {
        let suffix = UUID().uuidString
        let bundleIdentifier = "com.example.CameraFixturePreMutation.\(suffix)"
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(getpid())
        )
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: "pre-mutation-\(suffix)",
            cameraPermission: SimulatorCameraPermissionAdapter { _, _, _, _ in },
            compiledLibrary: { URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib") },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: "DEVICE")

        await #expect(throws: CancellationError.self) {
            try await adapter.configure(
                .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
                inferredApplication: nil,
                targetResolved: { _ in throw CancellationError() }
            )
        }

        #expect(await simctl.lifecycleMutationCount == 0)
        adapter.detachFromUnavailableDevice()
    }

    @Test("Intentional app termination suppresses automatic camera reinjection")
    @MainActor
    func intentionalTerminationSuppressesReinjection() async throws {
        let bundleIdentifier = "com.example.CameraFixture"
        let processIdentifier = Int32(getpid())
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: UUID().uuidString,
            cameraPermission: SimulatorCameraPermissionAdapter { _, _, _, _ in },
            compiledLibrary: { URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib") },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: "DEVICE")
        _ = try await adapter.configure(
            .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
            inferredApplication: nil
        )

        await adapter.prepareForIntentionalApplicationMutation(
            bundleIdentifier: bundleIdentifier
        )
        adapter.handleExitedInjection(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        for _ in 0..<100 { await Task.yield() }

        #expect(await simctl.injectedLaunchCount == 1)
        #expect(!adapter.status().injectedBundleIdentifiers.contains(bundleIdentifier))
    }

    @Test("Camera mutation waits for host cleanup ownership")
    @MainActor
    func cameraMutationWaitsForCleanupOwnership() async throws {
        let bundleIdentifier = "com.example.CameraFixture"
        let ownershipGate = CameraTargetOwnershipGate()
        let permission = CameraPermissionRecorder()
        let simctl = CameraReinjectionSimctlFake(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(getpid())
        )
        let adapter = SimulatorCameraAdapter(
            sharedMemoryToken: UUID().uuidString,
            cameraPermission: SimulatorCameraPermissionAdapter {
                device, action, service, bundle in
                await permission.record(
                    device: device,
                    action: action,
                    service: service,
                    bundle: bundle
                )
            },
            compiledLibrary: { URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib") },
            simctl: { arguments, environment in
                await simctl.run(arguments: arguments, environment: environment)
            }
        )
        adapter.attach(deviceIdentifier: "DEVICE")
        let operation = Task { @MainActor in
            try await adapter.configure(
                .targeted(bundleIdentifier: bundleIdentifier, source: .placeholder),
                inferredApplication: nil,
                targetResolved: { bundleIdentifier in
                    await ownershipGate.transfer(bundleIdentifier: bundleIdentifier)
                }
            )
        }

        #expect(await ownershipGate.waitUntilStarted() == bundleIdentifier)
        #expect(await permission.mutation == nil)
        #expect(await simctl.lifecycleMutationCount == 0)
        await ownershipGate.release()
        _ = try await operation.value

        #expect(await permission.mutation?.bundle == bundleIdentifier)
        #expect(await simctl.injectedLaunchCount == 1)
        await adapter.shutdown()
    }

    @Test("simctl launch output extracts the injected app pid")
    func launchOutput() {
        #expect(
            simulatorCameraProcessIdentifier(
                fromLaunchOutput: "com.example.CameraFixture: 4312\n"
            ) == 4312
        )
    }

    @Test("Malformed launch output remains unknown")
    func malformedLaunchOutput() {
        #expect(
            simulatorCameraProcessIdentifier(fromLaunchOutput: "launch failed") == nil
        )
    }

    @Test("Camera injection accepts installed user apps and rejects Simulator system apps")
    func validatesCameraTarget() {
        let applications = """
        {
            "com.example.CameraFixture" = {
                ApplicationType = User;
                Path = "/Users/test/Library/Developer/CoreSimulator/Devices/DEVICE/data/Containers/Bundle/Application/APP/CameraFixture.app";
            };
            "com.apple.springboard" = {
                ApplicationType = System;
                Path = "/Applications/Xcode.app/RuntimeRoot/System/Library/CoreServices/SpringBoard.app";
            };
        }
        """

        #expect(simulatorCameraIsInstalledUserApplication(
            bundleIdentifier: "com.example.CameraFixture",
            listApplicationsOutput: applications
        ))
        #expect(!simulatorCameraIsInstalledUserApplication(
            bundleIdentifier: "com.apple.springboard",
            listApplicationsOutput: applications
        ))
        #expect(!simulatorCameraIsInstalledUserApplication(
            bundleIdentifier: "com.example.Missing",
            listApplicationsOutput: applications
        ))
    }

    @Test("Automatic camera access uses the transactional private TCC adapter")
    func cameraPermissionGrant() async throws {
        let recorder = CameraPermissionRecorder()
        let adapter = SimulatorCameraPermissionAdapter { device, action, service, bundle in
            await recorder.record(device: device, action: action, service: service, bundle: bundle)
        }

        try await adapter.grant(
            deviceIdentifier: "DEVICE",
            bundleIdentifier: "com.example.CameraFixture"
        )

        let mutation = await recorder.mutation
        #expect(mutation?.device == "DEVICE")
        #expect(mutation?.action == .grant)
        #expect(mutation?.service == .camera)
        #expect(mutation?.bundle == "com.example.CameraFixture")
    }
}
