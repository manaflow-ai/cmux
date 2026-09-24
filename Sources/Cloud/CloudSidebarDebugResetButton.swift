#if DEBUG
import SwiftUI

/// Resets only the supplied binding, preserving every other tuning value.
struct CloudSidebarDebugResetButton<Value: Equatable>: View {
    let title: String
    @Binding var value: Value
    let defaultValue: Value
    let defaultLabel: String

    private var resetDescription: String {
        String(
            format: String(localized: "debug.cloudSidebarSpacing.resetValue", defaultValue: "Reset %1$@ to %2$@"),
            title,
            defaultLabel
        )
    }

    var body: some View {
        Button {
            value = defaultValue
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(resetDescription)
        .accessibilityLabel(resetDescription)
        .accessibilityIdentifier("CloudSidebarReset." + title)
        .disabled(value == defaultValue)
    }
}

#endif
