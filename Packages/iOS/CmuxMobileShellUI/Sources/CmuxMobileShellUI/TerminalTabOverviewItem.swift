import CmuxMobileShellModel
import Foundation

struct TerminalTabOverviewItem: Identifiable, Equatable, Sendable {
    var id: MobileTerminalPreview.ID
    var title: String
    var previewLines: [String]
    var isSelected: Bool
    var canClose: Bool
}
