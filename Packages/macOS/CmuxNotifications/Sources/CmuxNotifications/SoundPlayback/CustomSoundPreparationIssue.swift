/// A failure encountered while staging a custom notification sound file into
/// `~/Library/Sounds` for ``CustomSoundStagingService``.
public enum CustomSoundPreparationIssue: Error {
    case emptyPath
    case missingFile(path: String)
    case missingFileExtension(path: String)
    case stagingFailed(path: String, details: String)

    var logMessage: String {
        switch self {
        case .emptyPath:
            return "Notification custom sound path is empty"
        case .missingFile(let path):
            return "Notification custom sound file does not exist: \(path)"
        case .missingFileExtension(let path):
            return "Notification custom sound requires a file extension: \(path)"
        case .stagingFailed(let path, let details):
            return "Failed to stage custom notification sound from \(path): \(details)"
        }
    }
}
