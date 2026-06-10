import Foundation
import SwiftUI

/// The input bar at the bottom of ``AgentChatView``.
///
/// A multi-line text input (plain Return sends, Shift+Return inserts a
/// newline) plus a send button. It owns only local `@State` (the draft text
/// and a send-failure flag) and talks to the app exclusively through the
/// injected ``ChatComposerActions`` closure bundle.
struct ChatComposerView: View {
    /// The injected send closure bundle.
    let actions: ChatComposerActions

    /// The draft text.
    @State private var text: String = ""

    /// Whether the last send attempt was rejected (target terminal gone).
    @State private var sendFailed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sendFailed {
                Text(
                    String(
                        localized: "agentChat.composer.sendFailed",
                        defaultValue: "Couldn’t send to the terminal.",
                        bundle: .module
                    )
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextInput(text: $text, onSubmit: send)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(
                                String(
                                    localized: "agentChat.composer.placeholder",
                                    defaultValue: "Message the agent (Shift+Return for a new line)",
                                    bundle: .module
                                )
                            )
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                        }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel(
                    String(localized: "agentChat.composer.send", defaultValue: "Send", bundle: .module)
                )
            }
        }
        .padding(10)
        .onChange(of: text) {
            if sendFailed { sendFailed = false }
        }
    }

    /// Whether the draft has sendable content.
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the draft through the injected closure; clears it on success.
    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if actions.send(trimmed) {
            text = ""
            sendFailed = false
        } else {
            sendFailed = true
        }
    }
}
