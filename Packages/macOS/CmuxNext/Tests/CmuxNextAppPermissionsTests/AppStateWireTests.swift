@testable import CmuxNextAppPermissions
import Foundation
import Testing

/// The wire shapes in plans/cmux-next/app-hide.md section 2 are the
/// contract with the Rust and DO owners: every example there decodes and
/// encodes back to the same JSON object. Examples are the fenced blocks
/// tagged `json app-state-<kind>`.
@Suite struct AppStateWireTests {
    static let doc = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/cmux-next/app-hide.md")

    /// `(kind, json)` for every tagged block.
    static func examples() throws -> [(String, String)] {
        let text = try String(contentsOf: doc, encoding: .utf8)
        var out: [(String, String)] = []
        var kind: String?
        var body: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let current = kind {
                if line.hasPrefix("```") {
                    out.append((current, body.joined(separator: "\n")))
                    kind = nil
                    body = []
                } else {
                    body.append(line)
                }
            } else if line.hasPrefix("```json app-state-") {
                kind = String(line.dropFirst("```json app-state-".count))
            }
        }
        return out
    }

    @Test func everyDocumentedExampleRoundTrips() throws {
        let examples = try Self.examples()
        #expect(Set(examples.map(\.0)) == ["record", "op", "commit", "reject"])
        let encoder = JSONEncoder()
        for (kind, json) in examples {
            let data = Data(json.utf8)
            let encoded: Data = switch kind {
            case "record": try encoder.encode(try JSONDecoder().decode(AppInstallState.self, from: data))
            case "op": try encoder.encode(try JSONDecoder().decode(AppStateOp.self, from: data))
            case "commit": try encoder.encode(try JSONDecoder().decode(AppStateCommit.self, from: data))
            default: try encoder.encode(try JSONDecoder().decode(AppStateReject.self, from: data))
            }
            let expected = try JSONSerialization.jsonObject(with: data) as? NSDictionary
            let actual = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            #expect(expected != nil && expected == actual, "\(kind): \(json)")
        }
    }

    @Test func everyOpKindRoundTrips() throws {
        let kinds: [AppStateOp.Kind] = [.install(.user), .install(.team), .install(.default), .remove(confirmed: false), .remove(confirmed: true),
                                        .enable, .disable, .hide, .unhide, .setHiddenAccess(cli: nil, mcp: false, automations: true)]
        for kind in kinds {
            let op = AppStateOp(key: "k", app: "cmux/usage", kind: kind)
            #expect(try JSONDecoder().decode(AppStateOp.self, from: JSONEncoder().encode(op)) == op)
        }
        let rejects: [AppStateReject] = [.originNotAllowed(.script), .notInstalled, .adminOnly, .keyReused, .reservedKey, .sourceNotAllowed(.team)]
        for reject in rejects {
            #expect(try JSONDecoder().decode(AppStateReject.self, from: JSONEncoder().encode(reject)) == reject)
        }
    }
}
