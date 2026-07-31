import Foundation

/// What a menu item does with its file. One case per outcome, so a request
/// cannot name an application and ask for the chooser at the same time.
enum FileExternalOpenRequestAction: Equatable {
    case open(applicationURL: URL?)
    case pickApplication
    case revealInFinder
}

/// The file and the action a menu item carries, shared by the file preview
/// header menu, the Files tree, and the Files search results.
final class FileExternalOpenRequest: NSObject {
    let fileURL: URL
    let action: FileExternalOpenRequestAction

    init(fileURL: URL, action: FileExternalOpenRequestAction) {
        self.fileURL = fileURL
        self.action = action
    }
}
