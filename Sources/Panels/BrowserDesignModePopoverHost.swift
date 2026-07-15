import SwiftUI

/// Presents the Design Mode composer as a floating card over the browser panel.
struct BrowserDesignModePopoverHost: View {
    @Bindable var controller: BrowserDesignModeController

    var body: some View {
        ZStack {
            if controller.isComposerPresented {
                BrowserDesignModePopover(controller: controller)
                    .padding(.bottom, 14)
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.98, anchor: .bottom))
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.2), value: controller.isComposerPresented)
    }
}
