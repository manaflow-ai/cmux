#if DEBUG
import SwiftUI

/// Resets only the supplied binding, preserving every other tuning value.
public struct CloudSidebarDebugResetButton<Value: Equatable>: View {
    public init(
        title: String,
        value: Binding<Value>,
        defaultValue: Value,
        defaultLabel: String
    ) {
        self.title = title
        self._value = value
        self.defaultValue = defaultValue
        self.defaultLabel = defaultLabel
    }

    public let title: String
    @Binding public var value: Value
    public let defaultValue: Value
    public let defaultLabel: String

    private var resetDescription: String {
        String(
            format: String(localized: "debug.cloudSidebarSpacing.resetValue", defaultValue: "Reset %1$@ to %2$@"),
            title,
            defaultLabel
        )
    }

    public var body: some View {
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
