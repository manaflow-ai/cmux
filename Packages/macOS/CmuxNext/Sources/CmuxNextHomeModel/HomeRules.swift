internal import CCmuxHomeFFI
internal import CmuxNextCompat
internal import Foundation

/// The Swift caller of the Rust home rules (cmux-tui/crates/cmux-home-rules): one JSON op,
/// `AREA.NAME` such as `inbox.sections`, run by cmux-app-ffi's `cmux_home_call`
/// (`include/cmux_home.h`, module `CCmuxHomeFFI`). What Home, the chat list and the Chief
/// show and decide lives in Rust; the Swift views ask it through here and stay views.
///
///     let names: [String] = try HomeRules.call("ops.list", HomeRules.Empty())
public nonisolated struct HomeRules {
    public nonisolated init() {}
    /// An op's empty request (`{}`).
    public nonisolated struct Empty: Codable, Sendable, Equatable {
        public init() {}
    }

    /// Runs `op` on `input` (encoded as a JSON object) and decodes its reply as `Out`.
    public static func call<In: Encodable, Out: Decodable>(_ op: String, _ input: In) throws -> Out {
        let request: Data
        do {
            request = try JSONEncoder().encode(input)
        } catch {
            throw HomeRulesError(op: op, code: .encode, detail: String(describing: error))
        }
        let reply = try callData(op, request)
        do {
            return try JSONDecoder().decode(Out.self, from: reply)
        } catch {
            throw HomeRulesError(op: op, code: .decode, detail: String(describing: error))
        }
    }

    /// Runs `op` on `json` (a JSON object, UTF-8) and returns its reply's JSON.
    public static func callJSON(_ op: String, _ json: String) throws -> String {
        let reply = try callData(op, Data(json.utf8))
        guard let text = String(data: reply, encoding: .utf8) else {
            throw HomeRulesError(op: op, code: .decode, detail: "reply is not UTF-8")
        }
        return text
    }

    /// `CMUX_HOME_ABI_VERSION` of the linked library.
    public static var abiVersion: UInt32 { cmux_home_abi_version() }

    static func callData(_ op: String, _ request: Data) throws -> Data {
        var out = CmuxHomeBytes(ptr: nil, len: 0)
        let status: Int32 = op.withCString { opPointer in
            request.withUnsafeBytes { raw in
                cmux_home_call(
                    opPointer,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    raw.count,
                    &out
                )
            }
        }
        BridgeByteMeter.record(op, sent: request.count, received: out.len)
        guard status == CMUX_HOME_OK else {
            throw HomeRulesError(op: op, code: HomeRulesError.Code(status: status), detail: nil)
        }
        // The reply buffer is Rust's: copy it, then hand it back to cmux_home_bytes_free once.
        defer { cmux_home_bytes_free(out) }
        guard let pointer = out.ptr, out.len > 0 else { return Data() }
        return Data(bytes: pointer, count: out.len)
    }
}

/// Why a home rules op gave no reply: the C ABI's status (`CMUX_HOME_ERR_*`), or the JSON
/// on either side of it.
public nonisolated struct HomeRulesError: Error, Equatable, Sendable, CustomStringConvertible {
    public nonisolated enum Code: Equatable, Sendable {
        /// `CMUX_HOME_ERR_NULL`: a null pointer where one is required.
        case null
        /// `CMUX_HOME_ERR_INVALID`: not UTF-8, or not the JSON the op takes.
        case invalidRequest
        /// `CMUX_HOME_ERR_UNKNOWN_OP`: no op of that name.
        case unknownOp
        /// `CMUX_HOME_ERR_PANIC`: a panic inside Rust, caught.
        case panic
        /// A status this caller does not know (a newer ABI).
        case status(Int32)
        /// The request did not encode to JSON.
        case encode
        /// The reply did not decode as the type asked for.
        case decode

        init(status: Int32) {
            switch status {
            case CMUX_HOME_ERR_NULL: self = .null
            case CMUX_HOME_ERR_INVALID: self = .invalidRequest
            case CMUX_HOME_ERR_UNKNOWN_OP: self = .unknownOp
            case CMUX_HOME_ERR_PANIC: self = .panic
            default: self = .status(status)
            }
        }
    }

    public let op: String
    public let code: Code
    public let detail: String?

    public init(op: String, code: Code, detail: String?) {
        self.op = op
        self.code = code
        self.detail = detail
    }

    public var description: String {
        "home rules op \(op): \(code)" + (detail.map { " (\($0))" } ?? "")
    }
}
