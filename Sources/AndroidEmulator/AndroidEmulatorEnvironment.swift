import CmuxAndroidEmulator
import CmuxFoundation
import Foundation

/// Composition root for Android tooling supplied by the user's SDK.
@MainActor
final class AndroidEmulatorEnvironment {
    let coordinator: AndroidEmulatorCoordinator
    let windowController: AndroidEmulatorWindowController

    init(appDelegate: AppDelegate) {
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
        let coordinator = AndroidEmulatorCoordinator(service: service)
        self.coordinator = coordinator
        self.windowController = AndroidEmulatorWindowController(
            coordinator: coordinator,
            onOpenInPane: { [weak appDelegate] device in
                appDelegate?.openAndroidEmulatorPane(device)
            }
        )
    }
}
