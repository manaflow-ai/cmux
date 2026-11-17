// SPDX-License-Identifier: GPL-3.0-or-later
// cmux Computer Use (docs/computer-use-helper.md). The cmux-tui daemon starts this
// executable (in "cmux Helper Host.app") with macOS responsibility disclaimed, so
// Accessibility and Screen Recording belong to cmux Computer Use, never to cmux or
// its shells. Modes:
//   cmux-helper-host host --layout-dir D --state-dir S --scope ID   (bootstrap line on fd 3)
//   cmux-helper-host worker computer-use|screen-sharing --layout-dir D ...
//   cmux-helper-host probe       (prints this process's grants and exits)
import AppKit
import CmuxHelperComputerUse
import CmuxHelperHost
import CmuxHelperScreenSharing
import CmuxHelperWire
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.helper-host.dev"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cmux-helper-host: \(message)\n".utf8))
    exit(2)
}

switch arguments.first {
case "probe":
    FileHandle.standardOutput.write(PermissionAuthority.probeLine())
    exit(0)
case "worker":
    guard let layoutDirectory = option("--layout-dir") else { fail("worker needs --layout-dir") }
    let layout = HelperHostLayout(directory: layoutDirectory)
    switch arguments.dropFirst().first.flatMap(HelperWorkerKind.init(rawValue:)) {
    case .computerUse:
        ComputerUseWorker().run(bundleIdentifier: bundleID)
    case .screenSharing:
        guard let state = option("--state-dir"), let scope = option("--scope") else { fail("screen-sharing needs --state-dir and --scope") }
        let headless = ProcessInfo.processInfo.environment["CMUX_HELPER_HOST_HEADLESS"] != "0"
        MainActor.assumeIsolated {
            ScreenSharingWorker(layout: layout, stateDirectory: state, keychainScope: "\(bundleID).\(scope)", headless: headless).run()
        }
    case nil:
        fail("unknown worker")
    }
case "host":
    guard let layoutDirectory = option("--layout-dir"), let state = option("--state-dir"), let scope = option("--scope") else {
        fail("host needs --layout-dir, --state-dir and --scope")
    }
    // LaunchServices can open this app by itself (Quit & Reopen): with no
    // daemon's bootstrap pipe there is nothing to serve.
    let bootstrapChannel = LineChannel(read: 3, write: 3)
    guard fcntl(3, F_GETFD) >= 0, let line = bootstrapChannel.readObject(), let bootstrap = HostBootstrap(line: line) else {
        exit(0)
    }
    close(3)
    guard LocalSocket.makePrivateDirectory(layoutDirectory), LocalSocket.makePrivateDirectory(state) else {
        fail("\(layoutDirectory) or \(state) is not a private directory of this user")
    }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = HelperHost(layout: HelperHostLayout(directory: layoutDirectory), bootstrap: bootstrap,
                              executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                              stateDirectory: state, scope: scope)
        app.delegate = host
        do { try host.start() } catch { fail("cannot serve: \(error)") }
        // The daemon waits for this line before it connects.
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        app.run()
    }
default:
    fail("usage: cmux-helper-host host|worker|probe")
}
