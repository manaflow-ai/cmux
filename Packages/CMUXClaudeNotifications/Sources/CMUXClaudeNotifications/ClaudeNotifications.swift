import Foundation

public enum ClaudeNotificationTypeNormalization {
    public static let ignoredTypesDefaultsKey = "claudeCodeIgnoredNotificationTypes"
    public static let ignoredTypesEnvironmentKey = "CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"
    public static let defaultIgnoredTypes: [String] = []

    public static func normalized(_ raw: String) -> String? {
        let collapsedWhitespace = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let normalized = collapsedWhitespace
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    public static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.compactMap(normalized))
    }

    public static func normalizedUniqueList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            guard let normalized = normalized(raw),
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }
}

public enum ClaudeNotificationTypeExtractionScope {
    case root
    case notificationPayload
}

public enum ClaudeNotificationTypeExtractor {
    public static func values(
        inRawFallback fallback: String,
        scope: ClaudeNotificationTypeExtractionScope = .root
    ) -> [String] {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        return values(inJSONValue: json, scope: scope)
    }

    public static func values(
        inJSONValue value: Any,
        scope: ClaudeNotificationTypeExtractionScope = .root
    ) -> [String] {
        if let object = value as? [String: Any] {
            var values = values(in: object, scope: scope)
            for key in ["notification", "data"] {
                if let nested = object[key] {
                    values.append(contentsOf: self.values(
                        inJSONValue: nested,
                        scope: .notificationPayload
                    ))
                }
            }
            return values
        }
        if let values = value as? [Any] {
            return values.flatMap { self.values(inJSONValue: $0, scope: scope) }
        }
        if let string = value as? String {
            return values(inRawFallback: string, scope: scope)
        }
        return []
    }

    private static func values(
        in object: [String: Any],
        scope: ClaudeNotificationTypeExtractionScope
    ) -> [String] {
        let keys: [String]
        switch scope {
        case .root:
            keys = ["notification_type", "matcher", "reason"]
        case .notificationPayload:
            keys = ["notification_type", "matcher", "reason", "type", "kind"]
        }
        return keys.compactMap { key in
            object[key] as? String
        }
    }
}

public enum ClaudeIgnoredNotificationTypesFileLoadResult: Equatable {
    case missing
    case invalid
    case parsed([String]?)
}

public enum ClaudeIgnoredNotificationSettings {
    public typealias DataPreprocessor = (Data) throws -> Data

    public static func ignoredTypesFromSettingsFiles(
        paths: [String],
        fileManager: FileManager = .default,
        preprocess: DataPreprocessor = { $0 }
    ) -> Set<String>? {
        for path in paths {
            switch load(at: path, fileManager: fileManager, preprocess: preprocess) {
            case .missing:
                continue
            case .invalid:
                return []
            case .parsed(let values):
                guard let values else {
                    return []
                }
                return ClaudeNotificationTypeNormalization.normalizedSet(values)
            }
        }

        return nil
    }

    public static func settingsPaths(
        primaryDisplayPath: String,
        legacyDisplayPath: String,
        appSupportDirectories: [URL],
        fileManager: FileManager = .default,
        environment: [String: String]
    ) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(standardized).inserted {
                paths.append(standardized)
            }
        }

        append(expandedSettingsPath(primaryDisplayPath, fileManager: fileManager, environment: environment))
        append(expandedSettingsPath(legacyDisplayPath, fileManager: fileManager, environment: environment))

        for appSupportURL in appSupportDirectories {
            append(
                appSupportURL
                    .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false)
                    .path
            )
        }

        return paths
    }

    public static func expandedSettingsPath(
        _ rawPath: String,
        fileManager: FileManager = .default,
        environment: [String: String]
    ) -> String {
        let homePath = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let expanded: String
        if rawPath == "~" {
            expanded = homePath
        } else if rawPath.hasPrefix("~/") {
            expanded = (homePath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else {
            expanded = rawPath
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public static func load(
        at path: String,
        fileManager: FileManager = .default,
        preprocess: DataPreprocessor = { $0 }
    ) -> ClaudeIgnoredNotificationTypesFileLoadResult {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard !isDirectory.boolValue,
              let data = fileManager.contents(atPath: path),
              !data.isEmpty,
              let sanitized = try? preprocess(data),
              let rootObject = try? JSONSerialization.jsonObject(with: sanitized, options: []),
              let root = rootObject as? [String: Any] else {
            return .invalid
        }

        guard let rawNotifications = root["notifications"] else {
            return .parsed(nil)
        }
        guard let notifications = rawNotifications as? [String: Any] else {
            return .invalid
        }
        guard let rawValues = notifications["ignoredClaudeNotificationTypes"] else {
            return .parsed(nil)
        }
        guard let values = rawValues as? [String] else {
            return .invalid
        }
        return .parsed(values)
    }
}

public enum ClaudeNotificationSuppression {
    public static func suppressedTypes(
        notificationTypes: Set<String>,
        ignoredTypes: Set<String>
    ) -> Set<String> {
        guard !ignoredTypes.isEmpty, !notificationTypes.isEmpty else {
            return []
        }
        return ignoredTypes.intersection(notificationTypes)
    }
}
