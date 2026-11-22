import Foundation

/// "Back to before this turn" for a Cloud chat (`cloud.turnCheckpoints`, off by default): the page
/// asks for a whole-machine checkpoint after each completed turn and for a rewind to one. The
/// sequence lives in Rust (cmux-cloud-api `owner.turn_checkpoint` / `owner.turn_rewind`); the app
/// only resolves the chat's workspace and machine and passes the person's Cloud token through.
public nonisolated enum AgentPaneCloudTurnRewind: Equatable, Sendable {
    /// `chat.turnCheckpoint {afterSeq}`: the checkpoint before the turn after completed turn `afterSeq`.
    case checkpoint(afterSeq: Int)
    /// `chat.rewindTurn {rowId}` (the sent prompt's row, `user-<seq>`) or `{turnSeq}`: the machine
    /// back to the checkpoint nearest before that prompt, the one `chat.turnCheckpoint` saved after
    /// the turn before it ended.
    case rewind(turnSeq: Int)

    public static let checkpointMethod = "chat.turnCheckpoint"
    public static let rewindMethod = "chat.rewindTurn"
    public static let methods: Set<String> = [checkpointMethod, rewindMethod]

    public init?(method: String, params: [String: Any]?) {
        switch method {
        case Self.checkpointMethod:
            guard let seq = Self.number(params, "afterSeq", from: 0) else { return nil }
            self = .checkpoint(afterSeq: seq)
        case Self.rewindMethod:
            guard let seq = Self.number(params, "turnSeq", from: 1) ?? Self.promptSeq(params) else { return nil }
            self = .rewind(turnSeq: seq)
        default:
            return nil
        }
    }

    /// The turn number the checkpoint is named for (`auto-t<turnSeq>` in Rust).
    public var turnSeq: Int {
        switch self {
        case .checkpoint(let afterSeq): afterSeq + 1
        case .rewind(let turnSeq): turnSeq
        }
    }

    public var method: String {
        switch self {
        case .checkpoint: Self.checkpointMethod
        case .rewind: Self.rewindMethod
        }
    }

    /// The page's prompt row id (`user-<seq>`, the prompt's transcript sequence) as a turn number.
    public static func rowID(turnSeq: Int) -> String { "user-\(turnSeq)" }

    /// `{rowId: "user-<seq>"}`'s seq: digits only, no leading zero, at least 1.
    private static func promptSeq(_ params: [String: Any]?) -> Int? {
        guard let params, Set(params.keys) == ["rowId"], let row = params["rowId"] as? String,
              row.hasPrefix("user-"), case let digits = row.dropFirst(5), (1...15).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.first != "0" else { return nil }
        return Int(digits)
    }

    /// The only key of `params`, a whole number of at least `minimum` (below 2^50).
    private static func number(_ params: [String: Any]?, _ key: String, from minimum: Int) -> Int? {
        guard let params, Set(params.keys) == [key] else { return nil }
        // A whole number only: NSNumber would coerce a boolean or 6.5 to a turn.
        guard let number = params[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), value >= minimum, value < 1 << 50 else { return nil }
        return value
    }
}
