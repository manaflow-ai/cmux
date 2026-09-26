import Foundation

/// A settings path as `cmux config get` reports it.
public struct CmuxSettingReading: Sendable, Equatable {
    /// The dotted path that was read.
    public let path: String
    /// The value cmux.json sets, or nil when the key is absent.
    public let configured: CmuxSettingValue?
    /// The schema default, or nil when the schema declares none.
    public let defaultValue: CmuxSettingValue?

    /// The value cmux uses: the configured value, else the default.
    public var effective: CmuxSettingValue? {
        configured ?? defaultValue
    }
}

extension JSONConfigStore {
    /// Reads one settings path straight from disk, validated the same way
    /// ``apply(_:)`` validates a write.
    ///
    /// - Throws: ``CmuxSettingChangeError`` for an unknown or non-setting
    ///   path, or a read/parse error for an unreadable file.
    public nonisolated func reading(at path: String) throws -> CmuxSettingReading {
        let planner = CmuxSettingChangePlanner()
        let jsonPath = try planner.settingPath(path)
        let root = try snapshotRoot()
        return CmuxSettingReading(
            path: path,
            configured: jsonPath.lookup(in: root).flatMap(CmuxSettingValue.init(jsonObject:)),
            defaultValue: planner.defaultValue(at: jsonPath).flatMap(CmuxSettingValue.init(jsonObject:))
        )
    }
}
