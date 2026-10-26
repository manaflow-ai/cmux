import CmuxNextCompat
import Foundation

/// The closed key and value sets of cmux.com's hang report decoder, copied from
/// `web/services/hangReports/wireSchema.ts` (main) for schema 2, and the schema 3 additions of
/// plans/cmux-next/hang-reports-DESIGN.md section 4. The server decodes with
/// `onExcessProperty: "error"`, so a key or a literal outside these sets is a `400` and the client
/// drops the whole report: a report the builder writes must pass these rules for its own schema.
///
/// Only the shape is checked (keys and literals); the bounds and patterns are the golden tests'.
struct HangReportServerRules {
    static let topLevelKeys: Set<String> = [
        "schema", "reportId", "installId", "day", "app", "os", "hardware", "counts", "hangs", "cpuExceptions",
        "stallHistogram", "metrics", "intervals",
    ]
    /// Schema 3's top-level additions: the launches and the input latency fields.
    static let schema3TopLevelKeys: Set<String> = [
        "launches", "input_latency_bucket_edges_ms", "input_latency", "scroll_jank",
    ]
    static let hangKeys: Set<String> = ["source", "kind", "durationMs", "cpuMs", "frames"]
    static let frameKeys: Set<String> = ["image", "uuid", "offset"]

    /// What the server accepts in `hangs[]` for one schema.
    struct HangRules {
        var keys: Set<String>
        var sources: Set<String>
        var kinds: Set<String>
    }

    static func hangRules(schema: Int) -> HangRules? {
        switch schema {
        case 2:
            return HangRules(keys: hangKeys, sources: ["metrickit", "watchdog"], kinds: ["hang", "stall"])
        case 3:
            return HangRules(keys: hangKeys.union(["blocking"]), sources: ["metrickit", "watchdog", "detector"],
                             kinds: ["hang", "stall", "blocking"])
        default:
            return nil
        }
    }

    /// Schema 3's `hangs[].blocking`: closed sets, the detector's raw values.
    static let blockingKeys: Set<String> = ["kind", "context"]
    static let blockingKinds = Set(BlockingKind.allCases.map(\.rawValue))
    static let blockingContexts = Set(BlockingContext.allCases.map(\.rawValue))

    /// Every way `body` breaks the rules of the schema it names; empty when the server would take it.
    static func violations(in body: Data) -> [String] {
        guard let report = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return ["not a JSON object"] }
        guard let schema = report["schema"] as? Int, let rules = hangRules(schema: schema) else {
            return ["schema \(String(describing: report["schema"])) is not accepted"]
        }
        var found = extraKeys(report, allowed: schema == 3 ? topLevelKeys.union(schema3TopLevelKeys) : topLevelKeys,
                              at: "report")
        for (index, hang) in ((report["hangs"] as? [[String: Any]]) ?? []).enumerated() {
            found += hangViolations(hang, rules: rules, at: "hangs[\(index)]")
        }
        return found
    }

    private static func hangViolations(_ hang: [String: Any], rules: HangRules, at path: String) -> [String] {
        var found = extraKeys(hang, allowed: rules.keys, at: path)
        let source = hang["source"] as? String ?? ""
        let kind = hang["kind"] as? String ?? ""
        if !rules.sources.contains(source) { found.append("\(path).source \(source)") }
        if !rules.kinds.contains(kind) { found.append("\(path).kind \(kind)") }
        for (index, frame) in ((hang["frames"] as? [[String: Any]]) ?? []).enumerated() {
            found += extraKeys(frame, allowed: frameKeys, at: "\(path).frames[\(index)]")
        }
        // Schema 3: a blocking object exactly on a detector sample of kind blocking, with no duration.
        let isBlocking = source == "detector" || kind == "blocking"
        if isBlocking != (source == "detector" && kind == "blocking") { found.append("\(path) mixes detector and \(kind)") }
        guard let blocking = hang["blocking"] else {
            if isBlocking { found.append("\(path).blocking missing") }
            return found
        }
        guard isBlocking, let detail = blocking as? [String: Any] else { return found + ["\(path).blocking on a \(kind)"] }
        found += extraKeys(detail, allowed: blockingKeys, at: "\(path).blocking")
        if !blockingKinds.contains(detail["kind"] as? String ?? "") { found.append("\(path).blocking.kind") }
        if !blockingContexts.contains(detail["context"] as? String ?? "") { found.append("\(path).blocking.context") }
        if hang["durationMs"] as? Int != 0 { found.append("\(path).durationMs of a blocking sample") }
        return found
    }

    private static func extraKeys(_ object: [String: Any], allowed: Set<String>, at path: String) -> [String] {
        Set(object.keys).subtracting(allowed).sorted().map { "\(path).\($0) is not accepted" }
    }
}
