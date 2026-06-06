#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// iMessage-style composer pinned above the terminal.
///
/// A growing multi-line text field plus a send button. Send delivers the text
/// as a bracketed paste followed by a single Return (via `terminal.paste`), so a
/// multi-line message lands as one submission instead of fragmenting on every
/// interior newline. Toggled from the input accessory bar's composer button; the
/// chevron dismisses it.
struct TerminalComposerView: View {
    @Bindable var store: CMUXMobileShellStore
    @FocusState private var isFieldFocused: Bool

    private var trimmedIsEmpty: Bool {
        store.terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                store.toggleComposer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TerminalPalette.foreground.opacity(0.7))
            .accessibilityIdentifier("MobileComposerClose")
            .accessibilityLabel(L10n.string("mobile.composer.close", defaultValue: "Hide Composer"))

            TextField(
                L10n.string("mobile.composer.placeholder", defaultValue: "Message"),
                text: $store.terminalInputText,
                axis: .vertical
            )
            .lineLimit(1...8)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($isFieldFocused)
            .foregroundStyle(TerminalPalette.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(TerminalPalette.foreground.opacity(0.25), lineWidth: 1)
            )
            .accessibilityIdentifier("MobileComposerField")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .disabled(trimmedIsEmpty)
            .foregroundStyle(trimmedIsEmpty ? TerminalPalette.foreground.opacity(0.3) : Color.accentColor)
            .accessibilityIdentifier("MobileComposerSend")
            .accessibilityLabel(L10n.string("mobile.composer.send", defaultValue: "Send"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { isFieldFocused = true }
    }

    private func send() {
        guard !trimmedIsEmpty else { return }
        isFieldFocused = true
        Task { @MainActor in
            await store.submitComposerInput()
        }
    }
}
#endif
