import CmuxAgentChat
import SwiftUI

/// A centered fallback caption for wire payload types this client does not
/// understand (fail-open: the row stays visible instead of being dropped).
public struct ChatUnsupportedRowView: View {
    private let payload: ChatUnsupportedPayload

    /// Creates an unsupported-payload row.
    ///
    /// - Parameter payload: The unrecognized payload placeholder.
    public init(payload: ChatUnsupportedPayload) {
        self.payload = payload
    }

    public var body: some View {
        Text(
            String(
                localized: "chat.unsupported",
                defaultValue: "Unsupported message (\(payload.rawType))",
                bundle: .module
            )
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}
