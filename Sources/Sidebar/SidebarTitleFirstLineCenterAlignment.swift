import SwiftUI

enum SidebarTitleFirstLineCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let sidebarTitleFirstLineCenter = VerticalAlignment(SidebarTitleFirstLineCenterAlignment.self)
}
