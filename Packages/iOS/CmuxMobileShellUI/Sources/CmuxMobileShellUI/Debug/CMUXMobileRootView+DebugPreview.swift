#if DEBUG
import Foundation

enum MobileRootDebugPreviewRoute: Equatable {
    case panesTabs

    init?(environment: [String: String]) {
        guard environment["CMUX_UITEST_PANES_PREVIEW"] == "1" else {
            return nil
        }
        self = .panesTabs
    }
}

#if canImport(UIKit)
import SwiftUI

extension CMUXMobileRootView {
    var configuredDebugPreview: AnyView? {
        guard let route = MobileRootDebugPreviewRoute(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return nil
        }
        switch route {
        case .panesTabs:
            return AnyView(PanesTabsPreviewHost())
        }
    }
}
#endif
#endif
