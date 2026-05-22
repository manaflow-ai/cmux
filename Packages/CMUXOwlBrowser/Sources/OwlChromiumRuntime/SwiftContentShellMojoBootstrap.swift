import Darwin
import Foundation
import OwlBrowserCore
import OwlMojoSystem

struct SwiftContentShellMojoBootstrap {
    private let mojoSystem: DynamicMojoSystem
    private let rendezvousServerProvider: () throws -> MachPortRendezvousServer

    init(
        mojoSystem: DynamicMojoSystem,
        rendezvousServerProvider: @escaping () throws -> MachPortRendezvousServer = { try MachPortRendezvousServer.shared() }
    ) {
        self.mojoSystem = mojoSystem
        self.rendezvousServerProvider = rendezvousServerProvider
    }

    func createSession(
        chromiumHost: String,
        initialURL: String,
        userDataDirectory: String
    ) throws -> SwiftContentShellSession {
        let rendezvousServer = try rendezvousServerProvider()
        let channel = try MachPlatformChannel()
        let rendezvousKey = rendezvousServer.makeKey()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromiumHost)
        process.arguments = Self.arguments(
            initialURL: initialURL,
            userDataDirectory: userDataDirectory,
            rendezvousKey: rendezvousKey
        )
        process.environment = Self.environment()
        Self.configureMacOSWindowRestoration(chromiumHost: chromiumHost)

        do {
            try process.run()
        } catch {
            channel.destroy()
            throw OwlBrowserError.launch("failed to launch Chromium host \(chromiumHost): \(error)")
        }

        let processID = pid_t(process.processIdentifier)
        rendezvousServer.register(
            receiveRight: channel.takeRemoteReceiveRight(),
            key: rendezvousKey,
            processID: processID
        )

        let invitation = try mojoSystem.createInvitation()
        do {
            let shellControllerRemote = try mojoSystem.attachMessagePipe(toInvitation: invitation, name: 0)
            try mojoSystem.sendInvitation(
                invitation,
                toProcessID: processID,
                machSendRight: channel.takeLocalSendRight()
            )
            return SwiftContentShellSession(
                process: process,
                shellControllerRemoteHandle: UInt64(shellControllerRemote.rawValue),
                userDataDirectory: userDataDirectory
            )
        } catch {
            try? mojoSystem.close(invitation)
            rendezvousServer.unregister(processID: processID)
            process.terminate()
            throw error
        }
    }

    static func arguments(
        initialURL: String,
        userDataDirectory: String,
        rendezvousKey: UInt32
    ) -> [String] {
        var arguments = [
            "--no-sandbox",
            "--content-shell-hide-toolbar",
            "--no-first-run",
            "--no-default-browser-check",
            "--enable-logging=stderr",
            "--vmodule=*owl*=1,*fresh*=1,*shell*=1",
            "--mojo-platform-channel-handle=\(rendezvousKey)"
        ]
        if getenv("OWL_FRESH_NO_EMBED") == nil {
            arguments.append("--fresh-owl-embed")
            arguments.append("--fresh-owl-hosted-frame-pump")
        } else {
            arguments.append("--owl-fresh-visible-control")
        }
        if getenv("OWL_FRESH_ENABLE_DEVTOOLS") != nil {
            arguments.append("--owl-fresh-enable-devtools")
        } else {
            arguments.append("--owl-fresh-disable-devtools")
        }
        if getenv("OWL_FRESH_WINDOW_SNAPSHOT") != nil {
            arguments.append("--owl-fresh-window-snapshot")
        }
        if getenv("OWL_FRESH_LAYER_FIXTURE") != nil {
            arguments.append("--owl-fresh-layer-fixture-context")
        }
        if getenv("OWL_FRESH_DISABLE_GPU") != nil {
            arguments.append("--disable-gpu")
        }
        if getenv("OWL_FRESH_IN_PROCESS_GPU") != nil {
            arguments.append("--in-process-gpu")
        }
        if !userDataDirectory.isEmpty {
            arguments.append("--user-data-dir=\(userDataDirectory)")
        }
        if !initialURL.isEmpty {
            arguments.append(initialURL)
        }
        return arguments
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ApplePersistenceIgnoreState"] = "YES"
        environment["NSQuitAlwaysKeepsWindows"] = "NO"
        return environment
    }

    static func contentShellBundleIdentifier(chromiumHost: String) -> String? {
        let appURL = URL(fileURLWithPath: chromiumHost)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func configureMacOSWindowRestoration(chromiumHost: String) {
        guard let bundleIdentifier = contentShellBundleIdentifier(chromiumHost: chromiumHost),
              !bundleIdentifier.isEmpty else {
            return
        }
        let appID = bundleIdentifier as CFString
        CFPreferencesSetAppValue("ApplePersistenceIgnoreState" as CFString, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue("NSQuitAlwaysKeepsWindows" as CFString, kCFBooleanFalse, appID)
        CFPreferencesAppSynchronize(appID)
    }
}

final class SwiftContentShellSession {
    let process: Process
    let shellControllerRemoteHandle: UInt64
    let userDataDirectory: String
    private var observedTerminationStatus: Int32?

    init(process: Process, shellControllerRemoteHandle: UInt64, userDataDirectory: String) {
        self.process = process
        self.shellControllerRemoteHandle = shellControllerRemoteHandle
        self.userDataDirectory = userDataDirectory
    }

    func destroy() {
        if hasExited() {
            return
        }
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
    }

    func hasExited() -> Bool {
        if observedTerminationStatus != nil {
            return true
        }
        if !process.isRunning {
            observedTerminationStatus = process.terminationStatus
            return true
        }
        var status: Int32 = 0
        let result = waitpid(pid_t(process.processIdentifier), &status, WNOHANG)
        if result == pid_t(process.processIdentifier) {
            observedTerminationStatus = status
            return true
        }
        return false
    }

    var terminationStatusDescription: String {
        if let observedTerminationStatus {
            return "\(observedTerminationStatus)"
        }
        return "\(process.terminationStatus)"
    }
}
