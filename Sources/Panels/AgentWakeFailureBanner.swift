import AppKit
import SwiftUI

/// Shown above the terminal when an agent woken from hibernation did not come back.
struct AgentWakeFailureBanner: View {
    let failure: AgentWakeFailure
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.callout)
                        .accessibilityIdentifier("agent-wake-failure-message")
                    Text(failure.reason.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agent-wake-failure-detail")
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
                if failure.canRetry {
                    Button(retryTitle, action: onRetry)
                        .controlSize(.small)
                        .accessibilityIdentifier("agent-wake-failure-retry")
                }
                Button(showsCommand ? hideCommandTitle : showCommandTitle) {
                    showsCommand.toggle()
                }
                .controlSize(.small)
                .accessibilityIdentifier("agent-wake-failure-show-command")
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(closeTitle)
                .accessibilityLabel(closeTitle)
                .accessibilityIdentifier("agent-wake-failure-close")
            }
            if showsCommand {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: failure.commandText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("agent-wake-failure-command")
                    Button(copyTitle) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(failure.commandText, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("agent-wake-failure-copy")
                }
            }
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-wake-failure-banner")
    }

    private var message: String {
        String(
            format: String(
                localized: "agentWake.banner.message",
                defaultValue: "%@ didn't resume after waking."
            ),
            failure.agentDisplayName
        )
    }

    private var retryTitle: String {
        String(localized: "agentWake.banner.retry", defaultValue: "Retry")
    }

    private var showCommandTitle: String {
        String(localized: "agentWake.banner.showCommand", defaultValue: "Show command")
    }

    private var hideCommandTitle: String {
        String(localized: "agentWake.banner.hideCommand", defaultValue: "Hide command")
    }

    private var copyTitle: String {
        String(localized: "agentWake.banner.copy", defaultValue: "Copy")
    }

    private var closeTitle: String {
        String(localized: "agentWake.banner.close", defaultValue: "Close")
    }
}
