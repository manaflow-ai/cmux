import Darwin
import Foundation
import Security

/// macOS energy mode (the System Settings → Battery "Energy Mode" picker).
enum SleepyEnergyMode: Int, CaseIterable, Sendable {
    case automatic = 0
    case low = 1
    case high = 2

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "sleepyMode.energy.automatic", defaultValue: "Automatic")
        case .low: return String(localized: "sleepyMode.energy.low", defaultValue: "Low Power")
        case .high: return String(localized: "sleepyMode.energy.high", defaultValue: "High Power")
        }
    }

    var next: SleepyEnergyMode {
        SleepyEnergyMode(rawValue: (rawValue + 1) % 3) ?? .automatic
    }
}

/// Power actions for the Sleepy Mode control buttons. Sleeping the display is a
/// plain user action; changing the energy mode requires root, so it runs
/// `pmset` through Authorization Services (one admin prompt, cached ~5 min).
enum SleepyPowerControls {
    /// Turns the display off now. The user's idle-sleep assertion still holds, so
    /// the display stays awake against *idle*; this is an explicit manual sleep.
    static func sleepDisplayNow() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Engages the real macOS login lock via the supported `CGSession -suspend`
    /// mechanism (fast-user-switch to loginwindow; returning to the session
    /// requires the account password / Touch ID). This is the genuinely secure
    /// boundary — Apple's loginwindow, not our overlay — and it avoids depending
    /// on any private/undocumented login.framework symbol.
    static func lockMacNow() {
        run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
    }

    /// Reads the current energy mode without elevated privileges.
    static func currentEnergyMode() -> SleepyEnergyMode {
        guard let out = capture("/usr/bin/pmset", ["-g"]) else { return .automatic }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("powermode"),
               let value = line.split(separator: " ").compactMap({ Int($0) }).first,
               let mode = SleepyEnergyMode(rawValue: value) {
                return mode
            }
        }
        // Older hardware exposes only the binary lowpowermode.
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("lowpowermode") {
                return line.split(separator: " ").compactMap({ Int($0) }).first == 1 ? .low : .automatic
            }
        }
        return .automatic
    }

    private static let previousModeKey = "sleepyMode.preLowPowerMode"

    static func isLowPowerOn() -> Bool {
        currentEnergyMode() == .low
    }

    /// True on Macs that expose the 3-way `powermode` (Automatic/Low/High);
    /// older hardware exposes only the binary `lowpowermode`. Matches a line
    /// whose key is exactly `powermode` (not the `lowpowermode` substring).
    private static func supportsPowerMode() -> Bool {
        guard let out = capture("/usr/bin/pmset", ["-g"]) else { return false }
        for rawLine in out.split(separator: "\n") where rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("powermode") {
            return true
        }
        return false
    }

    /// Enables/disables Low Power Mode. On 3-mode Macs, enabling remembers the
    /// mode you were on and disabling restores it; on binary Macs it toggles
    /// `lowpowermode`. Returns the *re-read* state after the change applies, so
    /// the UI reflects reality even if the admin prompt was cancelled or the
    /// command failed.
    @discardableResult
    static func setLowPowerMode(_ enabled: Bool) -> Bool {
        let usesPowerMode = supportsPowerMode()
        if enabled {
            if usesPowerMode {
                let current = currentEnergyMode()
                if current != .low {
                    UserDefaults.standard.set(current.rawValue, forKey: previousModeKey)
                }
                runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(SleepyEnergyMode.low.rawValue)])
            } else {
                runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
            }
        } else if usesPowerMode {
            let storedRaw = UserDefaults.standard.object(forKey: previousModeKey) as? Int ?? SleepyEnergyMode.automatic.rawValue
            var restore = SleepyEnergyMode(rawValue: storedRaw) ?? .automatic
            if restore == .low { restore = .automatic }
            runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(restore.rawValue)])
        } else {
            runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "0"])
        }
        return isLowPowerOn()
    }

    // MARK: - Process helpers

    private static func run(_ launchPath: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func capture(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // AuthorizationExecuteWithPrivileges is unavailable in Swift, so load it
    // dynamically. Deprecated since 10.7 but still present in Security.framework;
    // it's the only one-shot privileged exec without a persistent helper, and is
    // scoped here to `pmset` only. macOS caches the admin credential ~5 min.
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef?,
        UnsafePointer<CChar>?,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    nonisolated(unsafe) private static let authExec: AuthExecFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: AuthExecFn.self)
    }()

    // One long-lived authorization for the whole app session. Reusing it (rather
    // than creating + destroying one per call) lets macOS keep the admin
    // credential cached (~5 min), so back-to-back toggles don't re-prompt.
    // `privilegedLock` serializes the lazy init and every privileged call, since
    // the toggle is invoked from detached tasks across one-overlay-per-display.
    nonisolated(unsafe) private static var sharedAuthorization: AuthorizationRef?
    private static let privilegedLock = NSLock()

    // Caller must hold `privilegedLock`.
    private static func authorizationRefLocked() -> AuthorizationRef? {
        if let sharedAuthorization { return sharedAuthorization }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        sharedAuthorization = ref
        return ref
    }

    @discardableResult
    private static func runPrivileged(_ tool: String, _ args: [String]) -> Bool {
        privilegedLock.lock()
        defer { privilegedLock.unlock() }
        guard let authExec, let authorization = authorizationRefLocked() else { return false }

        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }

        var pipe: UnsafeMutablePointer<FILE>?
        let status = tool.withCString { toolPtr -> OSStatus in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                authExec(authorization, toolPtr, 0, buffer.baseAddress, &pipe)
            }
        }
        // Drain the tool's output to EOF so we block until it actually exits;
        // callers can then re-read accurate state instead of guessing success.
        if let pipe {
            var line = [CChar](repeating: 0, count: 256)
            while fgets(&line, 256, pipe) != nil {}
            fclose(pipe)
        }
        return status == errAuthorizationSuccess
    }
}
