import Foundation

struct BrowserLocalFileIdentity: Equatable, Sendable {
    let canonicalPath: String

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
