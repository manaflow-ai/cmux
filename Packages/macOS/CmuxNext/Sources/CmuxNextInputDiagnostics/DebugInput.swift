public import CmuxNextControl
public import CmuxNextSettings
public import CmuxNextWakeups
internal import Foundation

/// `debug.input`: the input pipeline's counters as one JSON report, for agents and the fleet benches
/// (p04-input.md DC2, DC5, DC10). Registered in DEV and bench builds only, as `debug.action_budget`
/// is. Every read runs off the main thread on the request's task; a source with main-thread state
/// takes one snapshot copy there (``InputTapDebugSource``).
///
/// Params: `action` is `read` (the default), `reset`, `hops`, `dirty`, `hittest` or `slots`; `sections` (read)
/// limits the report to the named sections; `since_launch` (recorders) asks for every row since
/// launch.
///
/// ```swift
/// let debugInput = DebugInput(sources: [InputTapDebugSource(tap: services.inputTap, mainWork: services.mainWork), latencyReporter])
/// router.register([debugInput.method])
/// let report = try await debugInput.reply(to: .read(Set(DebugInputSection.allCases)))
/// ```
public nonisolated final class DebugInput: Sendable {
    /// The control method's name.
    public static let methodName = "debug.input"

    private let sources: [DebugInputSection: any DebugInputSource]
    private let recorders: [DebugInputRecorderKind: any DebugInputRecorder]

    /// A report over `sources` and `recorders`. Two producers of the same section or action: the
    /// later one in the list answers.
    public init(sources: [any DebugInputSource], recorders: [any DebugInputRecorder] = []) {
        self.sources = Dictionary(sources.map { ($0.section, $0) }, uniquingKeysWith: { _, later in later })
        self.recorders = Dictionary(recorders.map { ($0.kind, $0) }, uniquingKeysWith: { _, later in later })
    }

    /// The `debug.input` control method (async lane: off the main actor).
    public var method: ControlMethod {
        .async(Self.methodName) { [self] call in try await reply(to: Request(params: call.params)) }
    }

    /// The reply to one request.
    ///
    /// - Throws: ``ControlError`` `unavailable` for a recorder whose producer has not landed, or
    ///   `internal` when a section does not encode.
    public func reply(to request: Request) async throws(ControlError) -> JSONValue {
        switch request {
        case .read(let sections):
            return try await read(sections)
        case .reset:
            for section in DebugInputSection.allCases { await sources[section]?.reset() }
            for kind in DebugInputRecorderKind.allCases { await recorders[kind]?.reset() }
            let reset = DebugInputSection.allCases.filter { sources[$0] != nil }.map(\.rawValue)
                + DebugInputRecorderKind.allCases.filter { recorders[$0] != nil }.map(\.rawValue)
            return .object(["reset": .array(reset.map(JSONValue.string))])
        case .record(let kind, let sinceLaunch):
            guard let recorder = recorders[kind] else {
                throw ControlError(code: "unavailable", message: "debug.input \(kind.rawValue): no recorder in this build",
                                   data: ["action": .string(kind.rawValue)])
            }
            return try Self.json(await recorder.rows(sinceLaunch: sinceLaunch), name: kind.rawValue)
        }
    }

    private func read(_ sections: Set<DebugInputSection>) async throws(ControlError) -> JSONValue {
        var members: [String: JSONValue] = [:]
        var absent: [JSONValue] = []
        for section in DebugInputSection.allCases where sections.contains(section) {
            guard let source = sources[section] else {
                absent.append(.string(section.rawValue))
                continue
            }
            members[section.rawValue] = try Self.json(await source.read(), name: section.rawValue)
        }
        members["absent"] = .array(absent)
        return .object(members)
    }

    /// `value` as a JSON value. A non-finite number becomes the string `inf`, `-inf` or `nan`.
    private static func json(_ value: some Encodable, name: String) throws(ControlError) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            return try JSONValue.parse(encoder.encode(value))
        } catch {
            throw ControlError(code: "internal", message: "debug.input \(name) did not encode: \(error)")
        }
    }
}

extension DebugInput {
    /// One `debug.input` request, parsed from its params.
    public nonisolated enum Request: Sendable, Equatable {
        /// The named sections (every section when the params name none).
        case read(Set<DebugInputSection>)
        /// Every source and recorder starts over.
        case reset
        /// One recorder's rows.
        case record(DebugInputRecorderKind, sinceLaunch: Bool)

        /// Parses `params` (``DebugInput``'s list).
        ///
        /// - Throws: ``ControlError/invalidParams(_:data:)`` for an unknown action or section, a
        ///   param of the wrong type, or a param the action does not take (`sections` is for `read`
        ///   only, `since_launch` for the recorders only).
        public init(params: [String: JSONValue]) throws(ControlError) {
            let action: String
            switch params["action"] {
            case nil, .null?: action = "read"
            case .string(let name)?: action = name
            default: throw Self.invalid("action must be a string")
            }
            switch action {
            case "read":
                try Self.requireOnly(["action", "sections"], in: params, action: action)
                self = .read(try Self.sections(params["sections"]))
            case "reset":
                try Self.requireOnly(["action"], in: params, action: action)
                self = .reset
            default:
                guard let kind = DebugInputRecorderKind(rawValue: action) else {
                    let actions = ["read", "reset"] + DebugInputRecorderKind.allCases.map(\.rawValue)
                    throw Self.invalid("action must be one of \(actions.joined(separator: ", "))")
                }
                try Self.requireOnly(["action", "since_launch"], in: params, action: action)
                let sinceLaunch: Bool
                switch params["since_launch"] {
                case nil, .null?: sinceLaunch = false
                case .bool(let value)?: sinceLaunch = value
                default: throw Self.invalid("since_launch must be true or false")
                }
                self = .record(kind, sinceLaunch: sinceLaunch)
            }
        }

        private static func sections(_ value: JSONValue?) throws(ControlError) -> Set<DebugInputSection> {
            switch value {
            case nil, .null?:
                return Set(DebugInputSection.allCases)
            case .array(let names)?:
                var sections = Set<DebugInputSection>()
                for name in names {
                    guard let section = name.stringValue.flatMap(DebugInputSection.init(rawValue:)) else {
                        throw invalid("sections names one of \(DebugInputSection.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    sections.insert(section)
                }
                return sections
            default:
                throw invalid("sections must be an array of section names")
            }
        }

        /// Refuses a param `action` does not take, so a misspelled key (`sinceLaunch`) fails instead
        /// of being dropped.
        private static func requireOnly(_ allowed: Set<String>, in params: [String: JSONValue], action: String) throws(ControlError) {
            let unknown = params.keys.filter { !allowed.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw invalid("\(action) takes only \(allowed.sorted().joined(separator: ", ")); got \(unknown.joined(separator: ", "))")
            }
        }

        private static func invalid(_ message: String) -> ControlError {
            ControlError.invalidParams("debug.input: \(message)")
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.input` action `hops`: the input-turn hop recorder (machine queue
/// MQ-input-turn-hops). Its rows are the unique sites of main-actor jobs enqueued and non-Swift
/// callouts run during input turns, with count, kinds, origin and swift|nonswift. The read runs on
/// the global executor: the fold resolves stacks with `dladdr`, never on the main thread.
nonisolated extension MainJobGateDiagnostics: DebugInputRecorder {
    public var kind: DebugInputRecorderKind { .hops }

    public func rows(sinceLaunch: Bool) async -> MainJobGateDiagnostics.Snapshot {
        await resolvedSnapshot(sinceLaunch: sinceLaunch)
    }
}
#endif
