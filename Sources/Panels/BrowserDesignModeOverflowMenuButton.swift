import SwiftUI

struct BrowserDesignModeOverflowMenuButton: View {
    let controller: BrowserDesignModeController
    let isAvailable: Bool

    var body: some View {
        Button {
            Task { @MainActor in
                _ = await controller.toggle(reason: "overflowMenu")
            }
        } label: {
            Label(
                String(localized: "browser.designMode.title", defaultValue: "Design Mode"),
                systemImage: "paintbrush.pointed"
            )
        }
        .disabled(!isAvailable)
    }
}
