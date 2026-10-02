public import Foundation

/// The fixed allowlist of system changes the privileged helper may make
/// (plans/cmux-next/server.md 9.4). Each fix is one absolute executable and
/// argv chosen here; a request names a fix by id and never carries a command,
/// a path or a value. `revert` restores the macOS default.
public nonisolated enum ServerFix: String, CaseIterable, Sendable, Codable {
    /// `sleep.enabled`: no system sleep on AC power.
    case systemSleepOffOnAC = "pmset.ac.sleep.0"
    /// `sleep.enabled`: no disk sleep on AC power.
    case diskSleepOffOnAC = "pmset.ac.disksleep.0"
    /// `restart.noAutoRestart`: start again after a power failure.
    case autoRestartOn = "pmset.autorestart.1"
    /// Wake for network access, so a paired client can reach a sleeping server.
    case wakeOnNetworkOn = "pmset.womp.1"

    /// The health check id this fix belongs to (server.md 9.3).
    public var check: String {
        switch self {
        case .systemSleepOffOnAC, .diskSleepOffOnAC, .wakeOnNetworkOn: "sleep.enabled"
        case .autoRestartOn: "restart.noAutoRestart"
        }
    }

    public static let pmset = URL(filePath: "/usr/bin/pmset")

    /// The exact argv that applies the fix.
    public var applyArguments: [String] {
        switch self {
        case .systemSleepOffOnAC: ["-c", "sleep", "0"]
        case .diskSleepOffOnAC: ["-c", "disksleep", "0"]
        case .autoRestartOn: ["-a", "autorestart", "1"]
        case .wakeOnNetworkOn: ["-a", "womp", "1"]
        }
    }

    /// The exact argv that restores the macOS default.
    public var revertArguments: [String] {
        switch self {
        case .systemSleepOffOnAC: ["-c", "sleep", "1"]
        case .diskSleepOffOnAC: ["-c", "disksleep", "10"]
        case .autoRestartOn: ["-a", "autorestart", "0"]
        case .wakeOnNetworkOn: ["-a", "womp", "0"]
        }
    }
}

/// What the helper runs for one request. Tests and dry runs replace it.
public protocol ServerFixRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> Int32
}

/// Runs the allowlisted executable with no shell and an empty environment.
public nonisolated struct ProcessFixRunner: ServerFixRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = [:]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Records what would run (the prototype and tests never change a developer's Mac).
public final nonisolated class DryRunFixRunner: ServerFixRunner, @unchecked Sendable {
    private let lock = NSLock() // concurrency-allow: guards one array append or copy, never held across an await or IO
    private var calls: [(URL, [String])] = []

    public init() {}

    public var recorded: [(URL, [String])] {
        lock.withLock { calls }
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        record(executable, arguments)
        return 0
    }

    private func record(_ executable: URL, _ arguments: [String]) {
        lock.withLock { calls.append((executable, arguments)) }
    }
}
