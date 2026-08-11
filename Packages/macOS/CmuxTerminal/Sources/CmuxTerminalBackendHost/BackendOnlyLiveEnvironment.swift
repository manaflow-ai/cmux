internal import Foundation

func backendOnlyCurrentHomeDirectoryURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}
