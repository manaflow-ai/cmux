import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// Add Device in the app (plans/cmux-next/add-device-DESIGN.md): the list from the bundled
/// cmux-tui, and the hand-offs to the Add Machine and Add Server cards, so the enroll and the
/// approval each stay one flow. Every add or remove reads the device list again.
extension AddDeviceServices {
    static func app(_ services: AppServices) -> AddDeviceServices {
        AddDeviceServices(
            list: { [weak services] in await services?.devices.read() },
            addComputer: { [weak services] address, name in
                guard let services else { return }
                let card = services.addMachine
                card.open(destination: address, name: name, over: NSApp.mainWindow)
                card.model.perform(.add)
                // task-owner: ends with the enroll this click started
                Task { @MainActor [weak services] in _ = await card.finished(); await services?.devices.refresh() }
            },
            addByName: { [weak services] in _ = services?.registry.perform("machine.add") },
            enterCode: { [weak services] in _ = services?.registry.perform("server.addServer") },
            copy: { CloudPresenter.copy($0) })
    }
}

extension DeviceDirectory {
    static func app(_ services: AppServices) -> DeviceDirectory {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)).map { HostCLI(binary: $0, environment: SSHService.environment) }
        return DeviceDirectory(run: { await cli?.json($0, label: "device") },
                               removePhone: { [weak services] in await services?.iphone.removePhone(id: $0) })
    }
}
