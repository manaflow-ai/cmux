import CmuxSettingsUI
import Foundation
import SwiftUI

struct UsageTipsOverlay: View {
    let controller: UsageTipsController
    let windowID: UUID
    @LiveSetting(\.app.showUsageTips) private var showUsageTips

    var body: some View {
        Group {
            if let presentation = controller.presentation,
               presentation.windowID == windowID {
                UsageTipCard(
                    presentation: presentation,
                    onAcknowledge: controller.acknowledge,
                    onDismiss: controller.dismiss,
                    onOpenSettings: {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .app)
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.24), value: controller.presentation?.id)
        .onAppear {
            controller.register(windowID: windowID)
        }
        .onChange(of: showUsageTips) { _, isEnabled in
            controller.updateEnabled(isEnabled)
        }
        .onDisappear {
            controller.unregister(windowID: windowID)
        }
    }
}

extension View {
    func usageTipsOverlay(controller: UsageTipsController?, windowID: UUID) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let controller {
                UsageTipsOverlay(controller: controller, windowID: windowID)
            }
        }
    }
}
