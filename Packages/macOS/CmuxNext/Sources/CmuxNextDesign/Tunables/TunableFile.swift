public import Foundation

/// The override file and the "Copy changed values as JSON" export share one
/// readable encoding: numbers, booleans, strings (choices and colors) and
/// `{"response": r, "dampingFraction": d}` for springs.
///
/// ```json
/// {"version": 1, "values": {"drop.overlay.style": "insetCard", "motion.spring.move": {"response": 0.2, "dampingFraction": 0.9}}}
/// ```
public nonisolated enum TunableFile {
    public static let version = 1

    /// The value a JSON object stands for, read as `kind` (nil when it does
    /// not fit).
    public static func value(_ json: Any, as kind: TunableKind) -> TunableValue? {
        switch kind {
        case .number:
            // JSONSerialization gives NSNumber for both numbers and booleans.
            guard let number = json as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .number(number.doubleValue)
        case .bool:
            guard let number = json as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .bool(number.boolValue)
        case .choice:
            return (json as? String).map(TunableValue.choice)
        case .color:
            return (json as? String).flatMap(TunableColor.init(rawValue:)).map(TunableValue.color)
        case .spring:
            guard let object = json as? [String: Any], let response = (object["response"] as? NSNumber)?.doubleValue,
                  let damping = (object["dampingFraction"] as? NSNumber)?.doubleValue else { return nil }
            return .spring(SpringParameters(response: response, dampingFraction: damping))
        }
    }

    /// The file's bytes for `overrides` (sorted keys, pretty-printed).
    public static func encode(_ overrides: [String: TunableValue]) -> Data {
        let text = "{\n  \"values\" : \(object(overrides, indent: "  ")),\n  \"version\" : \(version)\n}\n"
        return Data(text.utf8)
    }

    /// `{"key" : value, ...}` with sorted keys and short numbers (0.06, not
    /// JSONSerialization's 0.059999999999999998), indented by `indent`.
    public static func object(_ values: [String: TunableValue], indent: String = "") -> String {
        guard !values.isEmpty else { return "{}" }
        let inner = indent + "  "
        let members = values.keys.sorted().compactMap { key in values[key].map { "\(inner)\(quote(key)) : \(literal($0))" } }
        return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
    }

    /// A JSON literal for one value.
    public static func literal(_ value: TunableValue) -> String {
        switch value {
        case .number(let number): TunableExport.format(number)
        case .bool(let flag): flag ? "true" : "false"
        case .choice(let raw): quote(raw)
        case .color(let color): quote(color.rawValue)
        case .spring(let spring):
            "{\"dampingFraction\" : \(TunableExport.format(spring.dampingFraction)), \"response\" : \(TunableExport.format(spring.response))}"
        }
    }

    /// A JSON string literal.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Raw values of a file's `values` object, by key (empty when the file
    /// is missing or unreadable). The store reads them against descriptors.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = root["values"] as? [String: Any] else { return [:] }
        return values
    }

    /// Reads `url`. Blocking file IO: call it off the main actor only.
    static func readRaw(_ url: URL) -> [String: Any] {
        // concurrency-allow: called from TunableStore.activate's detached task, never on the main actor
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return decode(data)
    }
}

/// Writes the newest override snapshot to the file off the main actor. A
/// burst (a slider drag) coalesces: the stream keeps only the newest
/// snapshot, so at most one stale write runs.
nonisolated final class TunableFileWriter: Sendable {
    private let continuation: AsyncStream<[String: TunableValue]>.Continuation
    private let task: Task<Void, Never>

    init(url: URL) {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: TunableValue].self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        // task-owner: the writer owns it; finishing the stream in deinit ends it.
        task = Task.detached(priority: .utility) {
            for await snapshot in stream {
                Self.write(snapshot, to: url)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func write(_ snapshot: [String: TunableValue]) {
        continuation.yield(snapshot)
    }

    private static func write(_ snapshot: [String: TunableValue], to url: URL) {
        let manager = FileManager.default
        if snapshot.isEmpty {
            try? manager.removeItem(at: url)
            return
        }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TunableFile.encode(snapshot).write(to: url, options: .atomic)
    }
}
