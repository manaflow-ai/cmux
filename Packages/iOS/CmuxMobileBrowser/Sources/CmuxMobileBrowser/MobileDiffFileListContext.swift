#if canImport(UIKit)
import CmuxMobileShellModel
import Foundation

struct MobileDiffFileListContext: Identifiable {
    let id = UUID()
    let files: [MobileDiffFile]
    let selectedFileID: String?
}
#endif
