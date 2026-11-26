import Foundation

/// A settings path as `cmux config get` reports it.
public struct CmuxSettingReading: Sendable, Equatable {
    /// The dotted path that was read.
    public let path: String
    /// The value cmux.json sets, or nil when the key is absent.
    public let configured: CmuxSettingValue?
    /// The value stored outside cmux.json, such as one set in the Settings
    /// window, or nil when there is none.
    public let live: CmuxSettingValue?
    /// The schema default, or nil when the schema declares none.
    public let defaultValue: CmuxSettingValue?

    /// The value cmux uses: the configured value, else the live value, else
    /// the default.
    public var effective: CmuxSettingValue? {
        configured ?? live ?? defaultValue
    }
}

extension JSONConfigStore {
    /// Reads one settings path straight from disk, validated the same way
    /// ``apply(_:)`` validates a write.
    ///
    /// - Parameter liveValues: Where to read the value of a key the file
    ///   doesn't set, as in ``apply(_:liveValues:)``.
    /// - Throws: ``CmuxSettingChangeError`` for an unknown or non-setting
    ///   path, or a read/parse error for an unreadable file.
    public nonisolated func reading(
        at path: String,
        liveValues: CmuxSettingLiveValues = .schemaDefaultsOnly
    ) throws -> CmuxSettingReading {
        let planner = CmuxSettingChangePlanner(liveValues: liveValues)
        let root = try snapshotRoot()
        let jsonPath = try planner.settingPath(path, root: root)
        let configured = jsonPath.lookup(in: root).flatMap(CmuxSettingValue.init(jsonObject:))
        return CmuxSettingReading(
            path: path,
            configured: configured,
            live: configured == nil ? planner.liveValue(at: jsonPath) : nil,
            defaultValue: planner.defaultValue(at: jsonPath).flatMap(CmuxSettingValue.init(jsonObject:))
        )
    }
}
