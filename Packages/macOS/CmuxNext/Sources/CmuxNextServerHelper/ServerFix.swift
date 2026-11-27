public import Foundation

/// The fixed allowlist of system changes the privileged helper may make
/// (plans/cmux-next/server.md 9.4). Each fix is one `pmset` setting and value
/// chosen here; a request names a fix by id and never carries a command, a
/// path or a value. The helper records the value it replaced, and `revert`
/// puts exactly that value back (never a guessed default).
public nonisolated enum ServerFix: String, CaseIterable, Sendable, Codable {
    /// `sleep.enabled`: no system sleep on AC power.
    case systemSleepOffOnAC = "pmset.ac.sleep.0"
    /// `sleep.enabled`: no disk sleep on AC power.
    case diskSleepOffOnAC = "pmset.ac.disksleep.0"
    /// `restart.noAutoRestart`: start again after a power failure.
    case autoRestartOn = "pmset.autorestart.1"
    /// Wake for network access on AC power, so a paired client can reach a sleeping server.
    case wakeOnNetworkOn = "pmset.ac.womp.1"

    /// The health check id this fix belongs to (server.md 9.3).
    public var check: String {
        switch self {
        case .systemSleepOffOnAC, .diskSleepOffOnAC, .wakeOnNetworkOn: "sleep.enabled"
        case .autoRestartOn: "restart.noAutoRestart"
        }
    }

    public static let pmset = URL(filePath: "/usr/bin/pmset")

    /// The power source flag: `-c` (AC only) or `-a` (every source; autorestart is system wide).
    var source: String {
        switch self {
        case .systemSleepOffOnAC, .diskSleepOffOnAC, .wakeOnNetworkOn: "-c"
        case .autoRestartOn: "-a"
        }
    }

    /// The `pmset` setting name.
    public var setting: String {
        switch self {
        case .systemSleepOffOnAC: "sleep"
        case .diskSleepOffOnAC: "disksleep"
        case .autoRestartOn: "autorestart"
        case .wakeOnNetworkOn: "womp"
        }
    }

    var appliedValue: Int {
        switch self {
        case .systemSleepOffOnAC, .diskSleepOffOnAC: 0
        case .autoRestartOn, .wakeOnNetworkOn: 1
        }
    }

    /// Values the helper reads, records and writes back (minutes or a flag).
    public static let allowedRange = 0...100_000

    /// The exact argv that applies the fix.
    public var applyArguments: [String] { arguments(setting: appliedValue) }

    /// The exact argv that puts `value` back.
    public func arguments(setting value: Int) -> [String] { [source, setting, String(value)] }

    /// Reads this fix's setting for AC power from `pmset -g custom` output, or
    /// nil when the section or the setting is missing or not a plain number.
    public func currentValue(inCustomOutput output: String) -> Int? {
        var inAC = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                inAC = line == "AC Power:"
                continue
            }
            guard inAC else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == setting, let value = Int(fields[1]), Self.allowedRange.contains(value) else { continue }
            return value
        }
        return nil
    }
}

/// The result of one allowlisted command.
public nonisolated struct FixRunResult: Sendable, Equatable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}
