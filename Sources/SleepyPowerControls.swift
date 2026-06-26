import Darwin
import Foundation
import Security

/// macOS energy mode (the System Settings → Battery "Energy Mode" picker).
enum SleepyEnergyMode: Int, Sendable {
    case automatic = 0
    case low = 1
    case high = 2
}

/// Seam for system command execution so UI/tests can inject a fake instead of
/// mutating the real machine.
protocol SleepyCommandRunning: Sendable {
    /// Fire-and-forget (e.g. `pmset displaysleepnow`, `CGSession -suspend`).
    func run(_ tool: String, _ args: [String])
    /// Run and capture stdout (e.g. `pmset -g`). No privileges.
    func capture(_ tool: String, _ args: [String]) -> String?
    /// Run a privileged tool via Authorization Services, waiting for it to exit.
    @discardableResult func runPrivileged(_ tool: String, _ args: [String]) -> Bool
}

/// Power actions for the Sleepy Mode control buttons.
protocol SleepyPowerControlling: Sendable {
    func sleepDisplayNow()
    func lockMacNow()
    func isLowPowerOn() -> Bool
    @discardableResult func setLowPowerMode(_ enabled: Bool) -> Bool
}

/// App power-action adapter for Sleepy Mode, constructed by the composition root
/// (`SleepyModeController`) and injected into the scene. It owns no global
/// state; system effects go through an injected `SleepyCommandRunning`, and the
/// remembered pre-low-power mode lives in an injected `UserDefaults`, so the
/// behavior can be exercised with a fake runner and isolated defaults.
final class SleepyPowerControls: SleepyPowerControlling {
    private let runner: SleepyCommandRunning
    private let defaults: UserDefaults
    private let previousModeKey = "sleepyMode.preLowPowerMode"

    init(runner: SleepyCommandRunning = SystemCommandRunner(), defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
    }

    /// Turns the display off now (the system idle-sleep assertion still holds, so
    /// this is an explicit manual sleep, not idle sleep).
    func sleepDisplayNow() {
        runner.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Engages the real macOS login lock via the supported `CGSession -suspend`
    /// mechanism (returning to the session requires the account password /
    /// Touch ID). This is the genuinely secure boundary — Apple's loginwindow,
    /// not our overlay — and avoids any private login.framework symbol.
    func lockMacNow() {
        runner.run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
    }

    func isLowPowerOn() -> Bool {
        currentEnergyMode() == .low
    }

    /// Enables/disables Low Power Mode. On 3-mode Macs, enabling remembers the
    /// mode you were on and disabling restores it; on binary Macs it toggles
    /// `lowpowermode`. Returns the re-read state after the change applies.
    @discardableResult
    func setLowPowerMode(_ enabled: Bool) -> Bool {
        let usesPowerMode = supportsPowerMode()
        if enabled {
            if usesPowerMode {
                let current = currentEnergyMode()
                if current != .low { defaults.set(current.rawValue, forKey: previousModeKey) }
                runner.runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(SleepyEnergyMode.low.rawValue)])
            } else {
                runner.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
            }
        } else if usesPowerMode {
            let storedRaw = defaults.object(forKey: previousModeKey) as? Int ?? SleepyEnergyMode.automatic.rawValue
            var restore = SleepyEnergyMode(rawValue: storedRaw) ?? .automatic
            if restore == .low { restore = .automatic }
            runner.runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(restore.rawValue)])
        } else {
            runner.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "0"])
        }
        return isLowPowerOn()
    }

    private func currentEnergyMode() -> SleepyEnergyMode {
        guard let out = runner.capture("/usr/bin/pmset", ["-g"]) else { return .automatic }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("powermode"),
               let value = line.split(separator: " ").compactMap({ Int($0) }).first,
               let mode = SleepyEnergyMode(rawValue: value) {
                return mode
            }
        }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("lowpowermode") {
                return line.split(separator: " ").compactMap({ Int($0) }).first == 1 ? .low : .automatic
            }
        }
        return .automatic
    }

    /// True on Macs exposing the 3-way `powermode`; matches a line whose key is
    /// exactly `powermode`, not the `lowpowermode` substring.
    private func supportsPowerMode() -> Bool {
        guard let out = runner.capture("/usr/bin/pmset", ["-g"]) else { return false }
        for rawLine in out.split(separator: "\n") where rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("powermode") {
            return true
        }
        return false
    }
}

/// Real command runner. Plain tools run via `Process`; privileged tools run
/// through Authorization Services. All privileged work is serialized on a
/// private queue that also owns the `AuthorizationRef`, so there is no shared
/// mutable global and the admin prompt is not guarded by a lock held elsewhere.
/// `AuthorizationExecuteWithPrivileges` is Swift-unavailable, so it's loaded via
/// `dlsym` (deprecated but present); the admin credential macOS caches (~5 min)
/// means back-to-back toggles don't re-prompt.
final class SystemCommandRunner: SleepyCommandRunning, @unchecked Sendable {
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef?,
        UnsafePointer<CChar>?,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let authExec: AuthExecFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: AuthExecFn.self)
    }()

    private let privilegedQueue = DispatchQueue(label: "com.cmux.sleepyMode.privileged")
    private var authorization: AuthorizationRef?  // accessed only on privilegedQueue

    func run(_ tool: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func capture(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) -> Bool {
        privilegedQueue.sync {
            guard let authExec = Self.authExec, let authorization = authorizationRefOnQueue() else { return false }
            var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cArgs.append(nil)
            defer { for pointer in cArgs where pointer != nil { free(pointer) } }
            var pipe: UnsafeMutablePointer<FILE>?
            let status = tool.withCString { toolPtr -> OSStatus in
                cArgs.withUnsafeMutableBufferPointer { buffer in
                    authExec(authorization, toolPtr, 0, buffer.baseAddress, &pipe)
                }
            }
            // Drain to EOF so we block until the tool exits and callers can
            // re-read accurate state.
            if let pipe {
                var line = [CChar](repeating: 0, count: 256)
                while fgets(&line, 256, pipe) != nil {}
                fclose(pipe)
            }
            return status == errAuthorizationSuccess
        }
    }

    // Lazily creates the long-lived authorization. Called only on privilegedQueue.
    private func authorizationRefOnQueue() -> AuthorizationRef? {
        if let authorization { return authorization }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        authorization = ref
        return ref
    }
}
