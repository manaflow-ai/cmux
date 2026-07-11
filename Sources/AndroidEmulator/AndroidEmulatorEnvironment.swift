import CmuxAndroidEmulator
import CmuxFoundation
import Foundation

/// Composition root for Android tooling supplied by the user's SDK.
@MainActor
final class AndroidEmulatorEnvironment {
    let coordinator: AndroidEmulatorCoordinator

    init() {
        let environment = ProcessInfo.processInfo.environment
        let locator = AndroidSDKLocator(
            environment: environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            files: SystemAndroidSDKFileChecker()
        )
        let service = AndroidEmulatorService(
            sdkLocator: locator,
            commands: CommandRunner(environment: environment),
            processLauncher: AndroidEmulatorProcessLauncher(baseEnvironment: environment),
            adbCommands: AndroidADBCommandRunner(environment: environment)
        )
        self.coordinator = AndroidEmulatorCoordinator(service: service)
    }
}
