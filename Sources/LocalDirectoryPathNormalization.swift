import Foundation

enum LocalDirectoryPathNormalization {
    static func existingDirectoryPath(
        _ path: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let normalizedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return normalizedPath
    }
}
