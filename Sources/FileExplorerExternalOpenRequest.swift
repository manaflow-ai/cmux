import Foundation

enum FileExplorerExternalOpenAction {
    case open(applicationURL: URL?)
    case revealInCmux
}

final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let action: FileExplorerExternalOpenAction

    init(fileURL: URL, action: FileExplorerExternalOpenAction) {
        self.fileURL = fileURL
        self.action = action
    }
}
