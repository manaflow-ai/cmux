import SwiftUI

struct BrowserDesignModeOverflowMenuButton: View {
    let controller: BrowserDesignModeController
    let onToggle: @MainActor () async -> Bool

    var body: some View {
        Button {
            Task { @MainActor in
                guard await onToggle() else { return }
            }
        } label: {
            Label(
                String(localized: "browser.designMode.title", defaultValue: "Design Mode"),
                systemImage: "paintbrush.pointed"
            )
        }
        .disabled(!controller.canToggle)
    }
}
