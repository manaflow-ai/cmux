import Foundation

enum WalkUsageError: Error, CustomStringConvertible {
    case help
    case missingValue(String)
    case unknownFlag(String)
    case notANumber(flag: String, value: String)
    case notPositive(String)
    case unknownFault(String)

    var description: String {
        switch self {
        case .help: WalkOptions.usage
        case .missingValue(let flag): "\(flag) needs a value"
        case .unknownFlag(let flag): "unknown flag \(flag)"
        case .notANumber(let flag, let value): "\(flag): \(value) is not a number"
        case .notPositive(let flag): "\(flag) must be at least 1"
        case .unknownFault(let name): "unknown fault \(name) (known: lost-detach)"
        }
    }
}

struct WalkOptions: Sendable {
    static let usage = """
    usage: oracle-input-walk (swift run OracleInputWalk) [--seed S] [--steps N] [--total-steps T | --walks W] [--jobs J] [--shrink-budget B]
                            [--out DIR] [--plant-fault F]
      --seed S           first walk's seed (default 1); walk i uses seed S+i
      --steps N          steps per walk (default 500)
      --total-steps T    walks enough to take T steps (default 1000000)
      --walks W          exactly W walks (overrides --total-steps); --seed X --walks 1 replays walk X
      --jobs J           walks run on J tasks at once (default: the active processor count)
      --shrink-budget B  runs one failure's shrink may spend (default 2000)
      --out DIR          where failing walks' minimized journals go (default oracle-input-walk-failures)
      --plant-fault F    plant a driver bug (lost-detach) to show violations are caught and shrunk
    """

    var seed: UInt64 = 1
    var steps = 500
    var totalSteps = 1_000_000
    var walks: Int?
    var jobs = ProcessInfo.processInfo.activeProcessorCount
    var shrinkBudget = 2_000
    var out = URL(fileURLWithPath: "oracle-input-walk-failures", isDirectory: true)
    var fault: AttachWorld.Fault?

    var walkCount: Int { walks ?? (totalSteps + steps - 1) / steps }

    init(arguments: [String]) throws(WalkUsageError) {
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            if flag == "--help" || flag == "-h" { throw .help }
            guard let value = rest.popFirst() else { throw .missingValue(flag) }
            switch flag {
            case "--seed": seed = try Self.number(value, flag)
            case "--steps": steps = try Self.positive(value, flag)
            case "--total-steps": totalSteps = try Self.positive(value, flag)
            case "--walks": walks = try Self.positive(value, flag)
            case "--jobs": jobs = try Self.positive(value, flag)
            case "--shrink-budget": shrinkBudget = try Self.number(value, flag)
            case "--out": out = URL(fileURLWithPath: value, isDirectory: true)
            case "--plant-fault":
                guard let planted = AttachWorld.Fault(rawValue: value) else { throw .unknownFault(value) }
                fault = planted
            default: throw .unknownFlag(flag)
            }
        }
    }

    private static func number<Number: FixedWidthInteger>(_ value: String, _ flag: String) throws(WalkUsageError) -> Number {
        guard let number = Number(value) else { throw .notANumber(flag: flag, value: value) }
        return number
    }

    private static func positive(_ value: String, _ flag: String) throws(WalkUsageError) -> Int {
        let parsed: Int = try Self.number(value, flag)
        guard parsed > 0 else { throw .notPositive(flag) }
        return parsed
    }
}
