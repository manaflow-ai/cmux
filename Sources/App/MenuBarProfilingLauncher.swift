import AppKit
import Foundation
import os.log

nonisolated private let menuBarProfilingLogger = Logger(subsystem: "com.cmuxterm.app", category: "MenuBarProfiling")

enum MenuBarProfilingLauncher {
    static let defaultDurationSeconds = 15

    static func bundledScriptURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "start-cmux-profiling", withExtension: nil, subdirectory: "bin")
    }

    static func arguments(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        durationSeconds: Int = defaultDurationSeconds,
        openOutput: Bool = true
    ) -> [String] {
        var args = ["--pid", String(pid), "--duration", String(durationSeconds)]
        if openOutput {
            args.append("--open-output")
        }
        return args
    }

    @discardableResult
    static func start(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        scriptURL: URL? = bundledScriptURL()
    ) -> Bool {
        guard let scriptURL else {
            menuBarProfilingLogger.error("Unable to start profiling because bundled script is missing")
            NSSound.beep()
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments(pid: pid)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            menuBarProfilingLogger.notice("Started cmux profiling for pid \(pid)")
            return true
        } catch {
            menuBarProfilingLogger.error("Failed to start cmux profiling for pid \(pid): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return false
        }
    }
}
