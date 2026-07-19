import Foundation

enum CmuxRunURLExecutionError: Error, Equatable {
    case busy
    case workingDirectoryContainsUnsafeCharacters
    case workingDirectoryContainsSurroundingWhitespace
    case workingDirectoryMustBeAbsolute
    case workingDirectoryNotFound
    case workingDirectoryResolutionTimedOut
    case workingDirectoryVerifierUnavailable
    case targetNotFound
    case remoteWorkspaceUnsupported
    case emptyPane
    case targetChanged
    case creationFailed
}
