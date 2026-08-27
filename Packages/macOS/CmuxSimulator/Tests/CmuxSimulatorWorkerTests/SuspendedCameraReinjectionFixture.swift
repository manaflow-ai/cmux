import CmuxSimulator
import Foundation
@testable import CmuxSimulatorWorker

@MainActor
func makeSuspendedCameraReinjectionFixture() async throws -> (
    adapter: SimulatorCameraAdapter,
    compileGate: CameraReinjectionCompileGate,
    simctl: CameraReinjectionSimctlFake
) {
    let bundleIdentifier = "com.example.CameraFixture"
    let processIdentifier = Int32(getpid())
    let compileGate = CameraReinjectionCompileGate(
        libraryURL: URL(fileURLWithPath: "/tmp/cmux-camera-test.dylib")
    )
    let simctl = CameraReinjectionSimctlFake(
        bundleIdentifier: bundleIdentifier,
        processIdentifier: processIdentifier
    )
    let adapter = SimulatorCameraAdapter(
        sharedMemoryToken: UUID().uuidString,
        cameraPermission: SimulatorCameraPermissionAdapter { _, _, _, _ in },
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
    return (adapter, compileGate, simctl)
}
