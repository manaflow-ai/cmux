import Foundation

struct CmuxRunWorkingDirectoryResolver {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(_ requestedPath: String) -> Result<String, CmuxRunURLExecutionError> {
        let expanded = (requestedPath as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else {
            return .failure(.workingDirectoryMustBeAbsolute)
        }

        let resolved = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.workingDirectoryNotFound)
        }
        return .success(resolved)
    }
}
