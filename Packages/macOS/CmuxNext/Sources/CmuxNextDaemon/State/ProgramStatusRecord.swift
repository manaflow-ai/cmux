import Foundation

/// One OSC 7501 program status record of a terminal (decision
/// OSC-7501-PROGRAM-STATUS; contract .cmux-scratch/nx-osc7501/CONTRACT.md v1):
/// `extra.program_status` on the terminal resource, owned by the session
/// host. `title` and `msg` are untrusted program text: plain text only,
/// never a link, a command or a reason to act.
public struct ProgramStatusRecord: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case idle, working, done, blocked, error
    }

    /// Why a blocked program waits.
    public enum Kind: String, Sendable, Hashable {
        case permission, question, auth
    }

    /// `""` is the root record (the program); `/` separates child ids.
    public var id: String
    public var state: State
    /// 0...100 with `working` or `blocked`, else nil.
    public var progress: Int?
    public var kind: Kind?
    /// Stable machine name (`cargo`, `claude`); never the only label shown.
    public var app: String?
    public var title: String?
    public var msg: String?
    /// Increases on every stored report of the terminal: with the terminal
    /// and record ids it keys "seen" for done and error.
    public var updatedSeq: UInt64

    public init(id: String = "", state: State, progress: Int? = nil, kind: Kind? = nil, app: String? = nil,
                title: String? = nil, msg: String? = nil, updatedSeq: UInt64 = 0) {
        self.id = id
        self.state = state
        self.progress = progress
        self.kind = kind
        self.app = app
        self.title = title
        self.msg = msg
        self.updatedSeq = updatedSeq
    }

    /// One record of the wire array; nil for a record without an id or a
    /// known state. An unknown kind decodes as nil (the contract's rule).
    init?(_ value: JSONValue) {
        guard case .object(let object) = value, let id = object["id"]?.stringValue,
              let state = object["state"]?.stringValue.flatMap(State.init(rawValue:)) else { return nil }
        var progress: Int?
        if case .number(let number)? = object["progress"], number.isFinite { progress = Int(min(max(number, 0), 100)) }
        self.init(id: id, state: state, progress: progress, kind: object["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
                  app: object["app"]?.stringValue, title: object["title"]?.stringValue, msg: object["msg"]?.stringValue,
                  updatedSeq: object["updated_seq"]?.stringValue.flatMap(UInt64.init) ?? 0)
    }

    /// `extra.program_status` of a terminal; absent and `[]` are the same.
    static func records(_ extra: [String: JSONValue]?) -> [ProgramStatusRecord] {
        guard case .array(let values)? = extra?["program_status"] else { return [] }
        return values.compactMap { ProgramStatusRecord($0) }
    }

    /// The terminal's strongest record (the contract's aggregate):
    /// blocked > error > working > done; idle counts as none. Among equal
    /// states the newest report wins.
    public static func strongest(_ records: [ProgramStatusRecord]) -> ProgramStatusRecord? {
        records.filter { $0.state != .idle }.max { a, b in
            (a.state.strength, a.updatedSeq) < (b.state.strength, b.updatedSeq)
        }
    }
}

extension ProgramStatusRecord.State {
    var strength: Int {
        switch self {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle: 0
        }
    }
}
