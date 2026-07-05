import CmuxMobileShellModel
import UniformTypeIdentifiers
import Foundation

enum MobileWorkspaceDragPayload {
    static let dropContentTypes: [UTType] = [.plainText, .text]

    static func provider(for workspaceID: MobileWorkspacePreview.ID) -> NSItemProvider {
        NSItemProvider(object: workspaceID.rawValue as NSString)
    }
}
