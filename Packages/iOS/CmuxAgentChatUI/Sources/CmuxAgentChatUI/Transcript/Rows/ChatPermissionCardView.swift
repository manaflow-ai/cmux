import CmuxAgentChat
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An actionable permission card: title, the gated command in a mono chip,
/// and Approve/Deny buttons. Once resolved it freezes into a receipt line.
/// Never collapsible.
public struct ChatPermissionCardView: View {
    private let request: ChatPermissionRequest
    private let timestamp: Date
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Set on the first decision tap so the buttons disarm immediately;
    /// answering is raw key injection over the Mac round-trip, and a second
    /// tap before the receipt echoes back would select a different option.
    @State private var tappedIndex: Int?

    /// Creates a permission card.
    ///
    /// - Parameters:
    ///   - request: The permission payload (pending or resolved).
    ///   - timestamp: When the request was raised; shown on the receipt.
    ///   - actions: Row action bundle.
    public init(request: ChatPermissionRequest, timestamp: Date, actions: ChatRowActions) {
        self.request = request
        self.timestamp = timestamp
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(request.subject)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.terminalCardText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.terminalCardFill, in: .rect(cornerRadius: 6))
                    .textSelection(.enabled)
                if let resolution = request.resolution {
                    receipt(resolution: resolution)
                } else {
                    decisionButtons
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accent, lineWidth: 1.5)
            )
            Spacer(minLength: 32)
        }
    }

    private var decisionButtons: some View {
        VStack(spacing: 8) {
            Button {
                decide(0)
            } label: {
                HStack(spacing: 6) {
                    if tappedIndex == 0 {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(
                        String(localized: "chat.permission.approve", defaultValue: "Approve", bundle: .module)
                    )
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(theme.accent, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ChatPermissionApprove")
            Button {
                decide(1)
            } label: {
                Text(
                    String(localized: "chat.permission.deny", defaultValue: "Deny", bundle: .module)
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.hairline, lineWidth: 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ChatPermissionDeny")
        }
        .disabled(tappedIndex != nil)
        .opacity(tappedIndex == nil ? 1 : 0.6)
    }

    private func decide(_ index: Int) {
        guard tappedIndex == nil else { return }
        tappedIndex = index
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        actions.answerOption(index)
    }

    private func receipt(resolution: ChatPermissionRequest.Resolution) -> some View {
        HStack(spacing: 4) {
            Image(systemName: receiptSymbolName(resolution: resolution))
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(verbatim: "\(receiptLabel(resolution: resolution)) · \(timestamp.formatted(.dateTime.hour().minute()))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func receiptSymbolName(resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved: return "checkmark"
        case .denied: return "xmark"
        case .expired: return "clock"
        }
    }

    private func receiptLabel(resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved:
            return String(
                localized: "chat.permission.approved", defaultValue: "Approved", bundle: .module
            )
        case .denied:
            return String(
                localized: "chat.permission.denied", defaultValue: "Denied", bundle: .module
            )
        case .expired:
            return String(
                localized: "chat.permission.expired", defaultValue: "Expired", bundle: .module
            )
        }
    }
}
