import CryptoKit
import Foundation

/// What the person saw on an agent's permission request (cx-aocz): the tool, the summary, the
/// exact command, the input summary of a tool without a command (paths, patterns), and whether
/// the Mac shortened any of it, as the phone renders them from the feed item's `prompt.action`.
/// The phone signs the sha256 of this canonical form; the Mac that posted the item computes it
/// over the text it posted and refuses a mismatch, so a changed item text cannot turn a seen
/// `ls` into an approved `rm`. A shortened request is never allowed from the phone (the person
/// did not see all of it). One definition, used by both sides.
public struct FeedApproveShownText: Hashable, Sendable {
    public var tool: String
    public var summary: String
    public var command: String
    /// A tool input without a command: field name to its shown value.
    public var input: [String: String]
    /// The Mac cut the command, an input value, a field name, or dropped fields.
    public var truncated: Bool

    public init(tool: String?, summary: String?, command: String?, input: [String: String] = [:],
                truncated: Bool = false) {
        self.tool = tool ?? ""
        self.summary = summary ?? ""
        self.command = command ?? ""
        self.input = input
        self.truncated = truncated
    }

    /// `prompt.action` of a feed item (`tool`, `summary`, `command`, `input`, `truncated`).
    /// `truncated` counts only as the JSON boolean true.
    public init(action: [String: Any]) {
        let truncated = (action["truncated"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }
        self.init(tool: action["tool"] as? String, summary: action["summary"] as? String,
                  command: action["command"] as? String,
                  input: (action["input"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
                  truncated: truncated ?? false)
    }

    /// Unambiguous: a version line, then each field as `<name>:<UTF-8 byte count>:<value>` on its
    /// own line (a value may hold newlines), the input fields by name, then `truncated:0|1`.
    public var canonical: Data {
        var text = "cmux-feed-shown-v2\n"
        for (name, value) in [("tool", tool), ("summary", summary), ("command", command)] {
            text += "\(name):\(value.utf8.count):\(value)\n"
        }
        for (key, value) in input.sorted(by: { $0.key < $1.key }) {
            text += "input:\(key.utf8.count):\(key):\(value.utf8.count):\(value)\n"
        }
        text += "truncated:\(truncated ? 1 : 0)\n"
        return Data(text.utf8)
    }

    /// Lowercase hex sha256 of ``canonical``.
    public var sha256: String {
        SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

/// The bytes a phone's presence key signs to answer an approve request it
/// cannot otherwise prove it answered (cx-aocz, chief-approved design):
/// `cmux-feed-approve-v1\n<environment>\n<user>\n<phone install>\n<Mac install>
/// \n<item id>\n<shown-text sha256>\n<decision>\n<scope>\n<ts ms>`.
public struct FeedApproveProofMessage: Hashable, Sendable {
    public var environment: String
    public var user: String
    public var phoneInstall: String
    public var macInstall: String
    public var item: String
    public var shownSHA256: String
    /// `allow` or `deny`.
    public var decision: String
    /// `once` or `session`.
    public var scope: String
    public var timestampMs: Int64

    public init(environment: String, user: String, phoneInstall: String, macInstall: String, item: String,
                shownSHA256: String, decision: String, scope: String, timestampMs: Int64) {
        self.environment = environment
        self.user = user
        self.phoneInstall = phoneInstall
        self.macInstall = macInstall
        self.item = item
        self.shownSHA256 = shownSHA256
        self.decision = decision
        self.scope = scope
        self.timestampMs = timestampMs
    }

    public var bytes: Data {
        let lines = ["cmux-feed-approve-v1", environment, user, phoneInstall, macInstall, item, shownSHA256,
                     decision, scope, String(timestampMs)]
        return Data(lines.joined(separator: "\n").utf8)
    }
}

/// The proof an approve answer carries (`answer.proof`): the signing install,
/// the time it signed and the base64url raw P-256 signature.
public struct FeedApproveProof: Hashable, Sendable {
    public var install: String
    public var timestampMs: Int64
    public var signature: String

    public init(install: String, timestampMs: Int64, signature: String) {
        self.install = install
        self.timestampMs = timestampMs
        self.signature = signature
    }

    public var value: JSONValue {
        .object(["install": .string(install), "ts": .integer(timestampMs), "sig": .string(signature)])
    }
}
