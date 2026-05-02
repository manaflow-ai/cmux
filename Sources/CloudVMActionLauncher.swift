import AppKit
import Foundation

@MainActor
final class CloudVMActionLauncher {
    static let shared = CloudVMActionLauncher()

    private var processes: [Int32: Process] = [:]

    private init() {}

    func terminateAll() {
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }

    @discardableResult
    func start(socketPath: String, preferredWindow: NSWindow?) -> Bool {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            presentStartFailure(
                summary: String(
                    localized: "command.cloudVM.failed.missingCLI",
                    defaultValue: "The bundled cmux CLI is missing from this app build."
                ),
                output: "",
                preferredWindow: preferredWindow
            )
            return false
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath, "vm", "new"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { terminatedProcess in
            let output = Self.processOutput(stdout: outputPipe, stderr: errorPipe)
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                Self.shared.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0 else { return }
                let format = String(
                    localized: "command.cloudVM.failed.exit",
                    defaultValue: "cmux vm new exited with status %d."
                )
                Self.shared.presentStartFailure(
                    summary: String(format: format, Int(terminationStatus)),
                    output: output,
                    preferredWindow: nil
                )
            }
        }

        do {
            try process.run()
            processes[process.processIdentifier] = process
#if DEBUG
            cmuxDebugLog("cloudVM.launch pid=\(process.processIdentifier) socket=\(socketPath)")
#endif
            return true
        } catch {
            presentStartFailure(
                summary: String(
                    localized: "command.cloudVM.failed.launch",
                    defaultValue: "cmux vm new could not be launched."
                ),
                output: error.localizedDescription,
                preferredWindow: preferredWindow
            )
            return false
        }
    }

    nonisolated private static func processOutput(stdout: Pipe, stderr: Pipe) -> String {
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func presentStartFailure(summary: String, output: String, preferredWindow: NSWindow?) {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitedOutput = String(trimmedOutput.prefix(2000))
        let informativeText = limitedOutput.isEmpty
            ? summary
            : "\(summary)\n\n\(limitedOutput)"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "command.cloudVM.failed.title", defaultValue: "Couldn't Start Cloud VM")
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let preferredWindow {
            alert.beginSheetModal(for: preferredWindow, completionHandler: nil)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }
}
