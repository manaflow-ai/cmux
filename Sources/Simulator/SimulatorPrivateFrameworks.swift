import Foundation
import ObjectiveC

/// Loads Apple's private CoreSimulator + SimulatorKit frameworks via `dlopen`
/// so we can talk to simulators directly without launching Simulator.app.
///
/// Reference: https://github.com/tddworks/baguette uses the same recipe
/// against Xcode 26's preview-kit. We deliberately avoid linking the
/// frameworks at build time so the Xcode path stays portable.
enum SimulatorPrivateFrameworks {
    private static let lock = NSLock()
    private static let developerDirLock = NSLock()
    private static var didLoad = false
    private static var lastError: String?
    private static var cachedDeveloperDir: String?

    @discardableResult
    static func ensureLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didLoad { return lastError == nil }
        didLoad = true

        let dev = developerDir()
        let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        let simKit = (dev as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")

        if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil {
            lastError = "CoreSimulator load failed: \(Self.dlerrorString())"
            return false
        }
        if dlopen(simKit, RTLD_NOW | RTLD_GLOBAL) == nil {
            lastError = "SimulatorKit load failed: \(Self.dlerrorString())"
            return false
        }
        return true
    }

    static var loadErrorMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    static func developerDir() -> String {
        developerDirLock.lock()
        defer { developerDirLock.unlock() }
        if let cachedDeveloperDir {
            return cachedDeveloperDir
        }

        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        task.arguments = ["-p"]
        task.standardOutput = pipe
        do { try task.run() } catch {
            let fallback = "/Applications/Xcode.app/Contents/Developer"
            cachedDeveloperDir = fallback
            return fallback
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : trimmed
        cachedDeveloperDir = resolved
        return resolved
    }

    private static func dlerrorString() -> String {
        guard let cstr = dlerror() else { return "(no dlerror)" }
        return String(cString: cstr)
    }
}
