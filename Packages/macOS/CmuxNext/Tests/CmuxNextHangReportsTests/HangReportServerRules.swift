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
    /// Schema 3's top-level additions: the launches, the input latency fields, the field data
    /// (p09-observability-063; the decoder of p09-observability-064 lists them) and the launch's features
    /// (p12-perf-process-151) and the main thread's blocking site counts (p12-perf-process-226).
    static let schema3TopLevelKeys: Set<String> = [
        "launches", "input_latency_bucket_edges_ms", "input_latency", "scroll_jank",
        "histograms", "stability", "blackbox", "launch_sections", "features_hash", "features", "blocking_sites",
    ]
    /// Schema 3's `blocking_sites[]` entry (wireSchema3.ts `BlockingSiteCount`).
    static let blockingSiteKeys: Set<String> = ["site", "kind", "count", "total_ms"]
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
            return HangRules(keys: hangKeys.union(["blocking", "task", "thread"]),
                             sources: ["metrickit", "watchdog", "detector", "hangwatch"], kinds: ["hang", "stall", "blocking"])
        default:
            return nil
        }
    }

    /// Schema 3's `hangs[].blocking`: closed sets, the detector's raw values.
    static let blockingKeys: Set<String> = ["kind", "context"]
    static let blockingKinds = Set(BlockingKind.allCases.map(\.rawValue))
    static let blockingContexts = Set(BlockingContext.allCases.map(\.rawValue))
    /// Schema 3's `hangs[].task` (p06-scheduler-203): on a watchdog hang only, the owner and class.
    static let taskKeys: Set<String> = ["owner", "class"]
    /// Schema 3's `hangs[].thread` (p09-observability-068, wireSchema.ts `HangV3.thread` and `isPairedThread`): exactly
    /// on a hang-watch hang, the registration's name and kind.
    static let threadKeys: Set<String> = ["name", "kind"]

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
        for (index, site) in ((report["blocking_sites"] as? [[String: Any]]) ?? []).enumerated() {
            found += extraKeys(site, allowed: blockingSiteKeys, at: "blocking_sites[\(index)]")
            if (site["site"] as? String)?.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) == nil {
                found.append("blocking_sites[\(index)].site")
            }
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
        if let task = hang["task"] {
            if source != "watchdog" || kind != "hang" { found.append("\(path).task on a \(source) \(kind)") }
            if let task = task as? [String: Any] {
                found += extraKeys(task, allowed: taskKeys, at: "\(path).task")
                if !(task["owner"] is String) || !(task["class"] is String) { found.append("\(path).task fields") }
            } else {
                found.append("\(path).task is not an object")
            }
        }
        // Schema 3: a thread object exactly on a hang-watch sample, which is a hang.
        let isThreadHang = source == "hangwatch"
        if isThreadHang, kind != "hang" { found.append("\(path) hangwatch \(kind)") }
        if isThreadHang != (hang["thread"] != nil) { found.append("\(path).thread on a \(source) sample, or missing") }
        if let thread = hang["thread"] as? [String: Any] {
            found += extraKeys(thread, allowed: threadKeys, at: "\(path).thread")
            if !(thread["name"] is String) || !(thread["kind"] is String) { found.append("\(path).thread fields") }
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
