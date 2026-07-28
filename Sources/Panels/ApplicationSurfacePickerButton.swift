import SwiftUI

struct ApplicationSurfacePickerButton: View {
    let window: ApplicationWindowDescriptor
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ApplicationSurfacePickerRow(window: window)
                .padding(.horizontal, 12)
                .background(
                    isHovering
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("ApplicationSurfaceWindow-\(window.windowID)")
    }
}
