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

    /// Single-line height shared by the field pill and the round buttons so they
    /// line up. The field grows taller for multi-line input; the buttons stay
    /// pinned to the bottom edge.
    private let controlHeight: CGFloat = 40

    private var trimmedIsEmpty: Bool {
        store.terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        composerSurface
            .onAppear { focusField() }
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
                    .frame(width: controlHeight, height: controlHeight)
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
            .focused($isFieldFocused)
            .foregroundStyle(TerminalPalette.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: controlHeight)
            .mobileGlassField(cornerRadius: 20)
            .accessibilityIdentifier("MobileComposerField")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: controlHeight, height: controlHeight)
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

    /// Focus the field one runloop after appearing. Setting `@FocusState` inline
    /// in `onAppear` is unreliable (the field may not be in the window yet);
    /// deferring lets it take first responder from the terminal input proxy
    /// while that keyboard is still up, so the keyboard hands over in place
    /// instead of dropping and re-animating.
    private func focusField() {
        Task { @MainActor in
            isFieldFocused = true
        }
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
