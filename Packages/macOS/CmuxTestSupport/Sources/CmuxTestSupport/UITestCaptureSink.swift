public import Foundation

/// The production ``TestCaptureWriting`` conformer: env-gated capture-file
/// writes, byte-for-byte faithful to the legacy `CmuxUITestCapture`
/// namespace it replaces.
///
/// In production launches none of the `CMUX_UI_TEST_*` variables are set,
/// so every call short-circuits to `false` before any I/O — the "no-op in
/// prod" behavior is data-driven, not build-configured.
///
/// Isolation: a stateless `Sendable` struct. Writes happen synchronously on
/// the calling thread (matching legacy timing so captures are ordered with
/// the interactions they record); `FileManager.default` and `FileHandle`
/// are used inside method scope only, so no non-Sendable state is stored.
public struct UITestCaptureSink: TestCaptureWriting {
    private let environment: [String: String]

    /// Creates a sink reading capture paths from `environment`.
    ///
    /// - Parameter environment: The process environment; tests pass a
    ///   fixture dictionary instead.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    @discardableResult
    public func appendLineIfConfigured(envKey: String, line: String) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        appendLine(line, to: url)
        return true
    }

    @discardableResult
    public func mutateJSONObjectIfConfigured(
        envKey: String,
        _ update: (inout [String: Any]) -> Void
    ) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        mutateJSONObject(at: url, update)
        return true
    }

    private func configuredURL(for envKey: String) -> URL? {
        guard let rawPath = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    private func appendLine(_ line: String, to url: URL) {
        ensureParentDirectory(for: url)
        let payload = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                if let existing = try? Data(contentsOf: url) {
                    var combined = existing
                    combined.append(payload)
                    try? combined.write(to: url, options: .atomic)
                } else {
                    try? payload.write(to: url, options: .atomic)
                }
            }
            return
        }

        try? payload.write(to: url, options: .atomic)
    }

    private func mutateJSONObject(
        at url: URL,
        _ update: (inout [String: Any]) -> Void
    ) {
        ensureParentDirectory(for: url)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        update(&payload)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func ensureParentDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
