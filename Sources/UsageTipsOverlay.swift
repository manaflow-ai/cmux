import CmuxSettingsUI
import Foundation
import SwiftUI

struct UsageTipsOverlay: View {
    let controller: UsageTipsController
    let windowID: UUID
    @LiveSetting(\.app.showUsageTips) private var showUsageTips

    var body: some View {
        let presentation = controller.presentation
        WindowAccessor(refreshID: presentation?.id.rawValue) { window in
            UsageTipsWindowOverlayController.attach(
                to: window,
                controller: controller,
                windowID: windowID
            ).update(presentation: presentation)
        }
        .frame(width: 0, height: 0)
        .onChange(of: showUsageTips) { _, isEnabled in
            controller.updateEnabled(isEnabled)
        }
    }
}

extension View {
    func usageTipsOverlay(controller: UsageTipsController?, windowID: UUID) -> some View {
        background {
            if let controller {
                UsageTipsOverlay(controller: controller, windowID: windowID)
            }
        }
    }
}
