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

    /// Enables/disables Low Power Mode. Enabling remembers the mode you were on;
    /// disabling restores it. Returns the resulting low-power state (so the UI
    /// reflects reality if the admin prompt was cancelled). Prompts for admin the
    /// first time, then uses the cached credential.
    @discardableResult
    static func setLowPowerMode(_ enabled: Bool) -> Bool {
        let current = currentEnergyMode()
        if enabled {
            if current != .low {
                UserDefaults.standard.set(current.rawValue, forKey: previousModeKey)
            }
            let ok = runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(SleepyEnergyMode.low.rawValue)])
            return ok ? true : (current == .low)
        } else {
            let storedRaw = UserDefaults.standard.object(forKey: previousModeKey) as? Int ?? SleepyEnergyMode.automatic.rawValue
            var restore = SleepyEnergyMode(rawValue: storedRaw) ?? .automatic
            if restore == .low { restore = .automatic }
            let ok = runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(restore.rawValue)])
            return ok ? false : (current == .low)
        }
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
        UnsafeMutableRawPointer?
    ) -> OSStatus

    nonisolated(unsafe) private static let authExec: AuthExecFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: AuthExecFn.self)
    }()

    // One long-lived authorization for the whole app session. Reusing it (rather
    // than creating + destroying one per call) lets macOS keep the admin
    // credential cached (~5 min), so back-to-back toggles don't re-prompt.
    nonisolated(unsafe) private static var sharedAuthorization: AuthorizationRef?

    private static func authorizationRef() -> AuthorizationRef? {
        if let sharedAuthorization { return sharedAuthorization }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        sharedAuthorization = ref
        return ref
    }

    @discardableResult
    private static func runPrivileged(_ tool: String, _ args: [String]) -> Bool {
        guard let authExec, let authorization = authorizationRef() else { return false }

        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }

        let status = tool.withCString { toolPtr -> OSStatus in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                authExec(authorization, toolPtr, 0, buffer.baseAddress, nil)
            }
        }
        return status == errAuthorizationSuccess
    }
}
