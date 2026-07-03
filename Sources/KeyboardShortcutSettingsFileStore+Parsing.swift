import CmuxFoundation
import Foundation

extension CmuxSettingsFileStore {
    func parseNullableHex(
        _ rawValue: Any?,
        path: String,
        sourcePath: String
    ) -> String?? {
        if rawValue is NSNull {
            return .some(nil)
        }
        guard let raw = rawValue as? String,
              let normalized = WorkspaceTabColorSettings.normalizedHex(raw) else {
            logInvalid(path, sourcePath: sourcePath)
            return nil
        }
        return .some(normalized)
    }

    func logInvalid(_ path: String, sourcePath: String) {
        cmuxSettingsFileStoreLogger.warning("ignoring invalid setting '\(path, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
    }

    func jsonDouble(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
