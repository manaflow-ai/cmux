import Darwin
import Foundation
import ObjectiveC.runtime

/// Loads private Simulator frameworks from the active Xcode without adding
/// version-specific load commands to the cmux binary.
final class SimulatorFrameworkLoader {
    let developerDirectory: String

    private let fileManager: FileManager
    private(set) var simulatorKitHandle: UnsafeMutableRawPointer?
    private var handles: [UnsafeMutableRawPointer] = []

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = FileManager(),
        developerDirectoryResolver: SimulatorDeveloperDirectoryResolver =
            SimulatorDeveloperDirectoryResolver()
    ) {
        self.fileManager = fileManager
        developerDirectory = developerDirectoryResolver.resolve(environment: environment)
    }

    deinit {
        // Framework objects may outlive this loader during process teardown.
        // The worker exits as a unit, so intentionally retain dlopen handles.
    }

    func load() throws {
        let coreSimulatorCandidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]
        guard loadFirst(coreSimulatorCandidates) != nil else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "CoreSimulator could not be loaded from the active Xcode."
            )
        }

        // SimulatorKit moved from Developer/Library/PrivateFrameworks to
        // Contents/SharedFrameworks in Xcode 27.
        let simulatorKitCandidates = [
            "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        guard let handle = loadFirst(simulatorKitCandidates) else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "SimulatorKit could not be loaded from \(developerDirectory)."
            )
        }
        simulatorKitHandle = handle
    }

    func symbol(named name: String) -> UnsafeMutableRawPointer? {
        if let simulatorKitHandle, let symbol = dlsym(simulatorKitHandle, name) {
            return symbol
        }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private func loadFirst(_ candidates: [String]) -> UnsafeMutableRawPointer? {
        for path in candidates where fileManager.fileExists(atPath: path) {
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                handles.append(handle)
                return handle
            }
        }
        return nil
    }

}
