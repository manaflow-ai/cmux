// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
import CryptoKit

/// The app a Computer Use agent wants to use (docs/computer-use-approvals.md): the target the
/// worker resolved, never the agent's words. A saved approval matches by `bundle_id`, else by
/// `executable`.
public nonisolated struct ComputerUseApprovalApp: Sendable, Hashable, Codable {
    public var bundleID: String?
    public var executable: String?
    public var name: String

    public init(bundleID: String?, executable: String?, name: String) {
        self.bundleID = bundleID?.isEmpty == true ? nil : bundleID
        self.executable = executable?.isEmpty == true ? nil : executable
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case executable
        case name
    }

    /// The identity the saved list compares: one of the two ids, never the display name.
    public var identity: String? {
        if let bundleID { return "bundle:" + bundleID }
        if let executable { return "exe:" + executable }
        return nil
    }

    public func sameApp(as other: ComputerUseApprovalApp) -> Bool {
        identity != nil && identity == other.identity
    }

    /// `{"bundle_id"|"executable", "name"}` for `approved_apps` and `revoke`.
    public var wire: [String: Any] {
        var fields: [String: Any] = ["name": name]
        if let bundleID { fields["bundle_id"] = bundleID } else if let executable { fields["executable"] = executable }
        return fields
    }

    /// Reads `{"bundle_id"?, "executable"?, "name"?}`; nil without either id.
    public init?(wire object: [String: Any]) {
        let bundleID = object["bundle_id"] as? String
        let executable = object["executable"] as? String
        self.init(bundleID: bundleID, executable: executable,
                  name: (object["name"] as? String) ?? bundleID ?? executable.map { ($0 as NSString).lastPathComponent } ?? "")
        guard identity != nil else { return nil }
    }
}

/// One `app_approval` question from the Computer Use worker, checked: every field present with
/// its type, and `digest` equal to the SHA-256 of the canonical JSON of the object without it.
/// A request that fails any check is refused (fail closed); nothing here trusts the worker's
/// digest.
public nonisolated struct ComputerUseApprovalRequest: Sendable, Equatable {
    public var nonce: String
    public var client: String
    public var machine: String
    public var session: String
    public var agent: String
    public var workspace: String
    public var target: ComputerUseApprovalApp
    public var tool: String
    public var risk: String
    public var createdMs: Int64
    public var waitUntilMs: Int64
    public var answerableUntilMs: Int64
    public var digest: String
    /// The request object as received (`digest` included), for the phone ask.
    public var object: [String: ComputerUseCanonicalJSON]

    /// The id people and the CLI use: the first 16 hex digits of the digest.
    public var id: String { String(digest.prefix(16)) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.digest == rhs.digest && lhs.object == rhs.object }

    /// Parses and checks the request object of an `app_approval` line.
    public init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let object = ComputerUseCanonicalJSON(foundation: raw),
              case .object(let fields) = object else { return nil }
        guard case .string(let digest)? = fields["digest"], Self.isHex(digest, count: 64),
              case .string(let nonce)? = fields["nonce"], Self.isHex(nonce, count: 32),
              case .integer(1)? = fields["v"],
              case .string(let client)? = fields["client"], !client.isEmpty,
              case .string(let machine)? = fields["machine"],
              case .string(let session)? = fields["session"],
              case .string(let agent)? = fields["agent"],
              case .string(let workspace)? = fields["workspace"],
              case .string(let tool)? = fields["tool"],
              case .string(let risk)? = fields["risk"],
              case .integer(let created)? = fields["created_ms"],
              case .integer(let waitUntil)? = fields["wait_until_ms"],
              case .integer(let answerableUntil)? = fields["answerable_until_ms"],
              created <= waitUntil, waitUntil <= answerableUntil,
              let target = raw["target"] as? [String: Any], let app = ComputerUseApprovalApp(wire: target) else { return nil }
        var unsigned = fields
        unsigned["digest"] = nil
        guard Self.digest(of: .object(unsigned)) == digest else { return nil }
        self.nonce = nonce
        self.client = client
        self.machine = machine
        self.session = session
        self.agent = agent
        self.workspace = workspace
        self.target = app
        self.tool = tool
        self.risk = risk
        self.createdMs = created
        self.waitUntilMs = waitUntil
        self.answerableUntilMs = answerableUntil
        self.digest = digest
        self.object = fields
    }

    /// Lowercase hex SHA-256 of `value`'s canonical bytes.
    public static func digest(of value: ComputerUseCanonicalJSON) -> String {
        SHA256.hash(data: value.canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The request as Foundation objects (the phone ask's `request`).
    public var foundationObject: [String: Any] {
        (ComputerUseCanonicalJSON.object(object).foundationObject as? [String: Any]) ?? [:]
    }

    /// Whether a decision may still count at `nowMs`.
    public func isAnswerable(nowMs: Int64) -> Bool { nowMs <= answerableUntilMs }
}

/// JSON as the approval wire hashes it: keys sorted by UTF-8 bytes, no whitespace, strings
/// escaped as serde_json does (`"`, `\`, `\b \f \n \r \t`, other controls as `\u00xx`), integers
/// only (a fraction refuses the request). Swift and Rust hash the same bytes
/// (`schemas/computer-use/approval-fixtures.json`).
public nonisolated indirect enum ComputerUseCanonicalJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([ComputerUseCanonicalJSON])
    case object([String: ComputerUseCanonicalJSON])

    /// From `JSONSerialization` output; nil for a fraction or an unknown type.
    public init?(foundation value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let double = number.doubleValue
                guard double.rounded() == double, abs(double) < 9.0e15 else { return nil }
                self = .integer(number.int64Value)
            }
        case let string as String: self = .string(string)
        case let array as [Any]:
            var items: [ComputerUseCanonicalJSON] = []
            for item in array {
                guard let parsed = ComputerUseCanonicalJSON(foundation: item) else { return nil }
                items.append(parsed)
            }
            self = .array(items)
        case let object as [String: Any]:
            var members: [String: ComputerUseCanonicalJSON] = [:]
            for (key, item) in object {
                guard let parsed = ComputerUseCanonicalJSON(foundation: item) else { return nil }
                members[key] = parsed
            }
            self = .object(members)
        default: return nil
        }
    }

    public var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .integer(let value): value
        case .string(let value): value
        case .array(let items): items.map(\.foundationObject)
        case .object(let members): members.mapValues(\.foundationObject)
        }
    }

    public var canonicalData: Data { Data(canonicalText.utf8) }

    public var canonicalText: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .integer(let value): out += String(value)
        case .string(let value): Self.writeString(value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            let keys = members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                members[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
