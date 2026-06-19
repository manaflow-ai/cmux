public import Foundation

/// A merge-on-write `[String: String]` capture file for XCUITest scenarios.
///
/// Several UI-test harnesses persist small flat string fields to a capture
/// file so an XCUITest run can read internal app state back (the multi-window
/// notification routing harness, the menu key-equivalent recorder, and the
/// jump-to-unread recorder all do this). Each write loads the current file,
/// merges the new keys over it, and re-serializes the whole object, so the
/// fields accumulate across stages.
///
/// This type owns that load / merge / write so the byte format lives in one
/// tested place instead of being copy-pasted at every instrumentation point.
/// It is deliberately distinct from ``UITestCaptureSink/mutateJSONObjectIfConfigured(envKey:_:)``:
/// that sink serializes with `.sortedKeys` and keys on an environment
/// variable, whereas these harnesses write **unsorted** keys
/// (`JSONSerialization.data(withJSONObject:)` with no options) to an explicit
/// path. Routing them through the sorted-keys sink would change the on-disk
/// key order, so this type reproduces the unsorted writer byte-for-byte.
///
/// Isolation: a stateless `Sendable` struct. The only stored value is the
/// capture-file path; all I/O happens synchronously inside method scope on the
/// calling thread (matching the legacy inline writers' timing so captures stay
/// ordered with the interactions they record).
public struct UITestKeyValueCaptureFile: Sendable {
    private let path: String

    /// Creates a capture file bound to `path`.
    ///
    /// - Parameter path: The absolute capture-file path the harness resolved
    ///   from its scenario environment variable.
    public init(path: String) {
        self.path = path
    }

    /// Reads the current capture object, returning `[:]` when the file is
    /// absent or is not a `[String: String]` JSON object.
    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    /// Merges `updates` over the current capture object and writes the result
    /// back atomically with **unsorted** keys.
    ///
    /// An absent or unparsable file is treated as empty before merging, and a
    /// serialization failure leaves the file untouched, exactly matching the
    /// legacy inline writers.
    ///
    /// - Parameter updates: The keys to overwrite or insert.
    public func merge(_ updates: [String: String]) {
        var payload = load()
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
