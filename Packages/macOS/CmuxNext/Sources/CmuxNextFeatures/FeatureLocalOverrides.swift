import CmuxNextCompat
public import Foundation
import os

/// The Labs page's local choices (resolution step 3), by feature name: what
/// Chrome keeps of about:flags in Local State
/// (components/flags_ui/pref_service_flags_storage.cc) and applies at the
/// next start. The file is `{"<name>": true|false}`; a name the registry does
/// not declare is never asked for, so it does nothing. The ``FeatureList``
/// asks it only on DEV and NIGHTLY.
public nonisolated struct FeatureLocalOverrides: FeatureLocalOverrideProvider, Sendable, Equatable {
    /// `<features folder>/local-overrides.json`.
    public static let fileName = "local-overrides.json"

    public let values: [String: Bool]

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "features")

    public init(values: [String: Bool] = [:]) {
        self.values = values
    }

    public func localOverride(for feature: Feature) -> Bool? {
        values[feature.name]
    }

    /// Why the file was not read or written.
    public enum FileError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The file exists and is not a JSON object of booleans; nothing applies.
        case unreadable(String)
        /// The file system refused the write.
        case notWritten(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): "local feature overrides unreadable: \(reason)"
            case .notWritten(let reason): "local feature overrides not written: \(reason)"
            }
        }
    }

    /// Reads `file`: no file is no choice, and a file that is not a JSON
    /// object of booleans is none either (its failure goes to the unified log,
    /// then to `report`). Blocking: call it on a ``BackgroundWork`` files lane
    /// (the App's launch read).
    public static func read(_ file: URL, report: (FileError) -> Void = { _ in }) -> FeatureLocalOverrides {
        let failure: FileError
        do {
            let data = try Data(blockingContentsOf: file)
            return FeatureLocalOverrides(values: try JSONDecoder().blockingDecode([String: Bool].self, from: data))
        } catch CocoaError.fileReadNoSuchFile {
            return FeatureLocalOverrides()
        } catch {
            failure = .unreadable(String(describing: error))
        }
        logger.error("\(failure.description, privacy: .public)")
        report(failure)
        return FeatureLocalOverrides()
    }

    /// Replaces `file` atomically with these values. Blocking: files lane only.
    public func save(to file: URL) -> FileError? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).blockingWrite(to: file, options: .atomic)
            return nil
        } catch {
            return .notWritten(String(describing: error))
        }
    }

    /// These values with `name` set to `value`, or without it for nil.
    public func setting(_ name: String, to value: Bool?) -> FeatureLocalOverrides {
        var values = values
        values[name] = value
        return FeatureLocalOverrides(values: values)
    }
}
