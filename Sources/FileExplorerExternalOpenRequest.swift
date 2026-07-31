import Foundation

final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let applicationURL: URL?
    /// Set by "Open With > Other…", where the application is chosen at click time.
    let picksApplication: Bool

    init(fileURL: URL, applicationURL: URL?, picksApplication: Bool = false) {
        self.fileURL = fileURL
        self.applicationURL = applicationURL
        self.picksApplication = picksApplication
    }
}
