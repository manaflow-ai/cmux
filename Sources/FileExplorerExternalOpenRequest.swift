import Foundation

final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let applicationURL: URL?

    init(fileURL: URL, applicationURL: URL?) {
        self.fileURL = fileURL
        self.applicationURL = applicationURL
    }
}
