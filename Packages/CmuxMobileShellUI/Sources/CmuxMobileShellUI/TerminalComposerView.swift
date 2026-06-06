#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// iMessage-style composer pinned above the terminal.
///
/// A growing multi-line text field plus a send button, rendered with Liquid
/// Glass (iOS 26+, with a thin-material fallback). Send delivers the text as a
/// bracketed paste followed by a single Return (via `terminal.paste`), so a
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
        composerSurface
            .onAppear { isFieldFocused = true }
    }

    /// On iOS 26 the glass controls float in a `GlassEffectContainer` over the
    /// terminal (no opaque bar — that would be glass-on-glass). Earlier OSes get
    /// a `.bar` material backing behind the material controls.
    @ViewBuilder
    private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                composerBar
            }
        } else {
            composerBar
                .background(.bar)
        }
    }

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                store.toggleComposer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TerminalPalette.foreground.opacity(0.7))
            .mobileGlassCircle()
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
            .foregroundStyle(TerminalPalette.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .mobileGlassField(cornerRadius: 20)
            .accessibilityIdentifier("MobileComposerField")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(trimmedIsEmpty ? TerminalPalette.foreground.opacity(0.35) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .mobileGlassCircle()
            .disabled(trimmedIsEmpty)
            .accessibilityIdentifier("MobileComposerSend")
            .accessibilityLabel(L10n.string("mobile.composer.send", defaultValue: "Send"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
