#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

/// iMessage-style composer hosted in the terminal surface's composer band.
///
/// A growing multi-line text field plus a send button, rendered with Liquid
/// Glass (iOS 26+, with a thin-material fallback). Send delivers the text as a
/// bracketed paste followed by a single Return (via `terminal.paste`), so a
/// multi-line message lands as one submission instead of fragmenting on every
/// interior newline. Toggled from the input accessory bar's composer button; the
/// chevron dismisses it.
///
/// The bottom dock (terminal grid / composer band / accessory toolbar / keyboard)
/// is owned entirely by `GhosttySurfaceView` in one coordinate system. This view is
/// hosted in a `UIHostingController` that `GhosttySurfaceRepresentable` installs into
/// the surface's composer band, directly above the always-visible accessory toolbar.
/// The view reports its measured height through ``onHeightChange`` so the surface can
/// reserve exactly that much above the toolbar; a field-grow therefore pushes ONLY the
/// terminal up while the toolbar and keyboard below stay put. There is no
/// `safeAreaInset` and no toolbar handoff — the prior rounds' two-layout-systems fight
/// is gone because there is only one layout system (the surface).
struct TerminalComposerView: View {
    @Bindable var store: CMUXMobileShellStore
    /// Asks the host to re-measure and re-size the surface's composer band. Fired
    /// whenever the field's content changes (the only driver of this view's height);
    /// the host measures the ideal height via `sizeThatFits` and animates the band.
    let requestHeightRemeasure: () -> Void
    @FocusState private var isFieldFocused: Bool

    init(store: CMUXMobileShellStore, requestHeightRemeasure: @escaping () -> Void) {
        self.store = store
        self.requestHeightRemeasure = requestHeightRemeasure
    }

    /// Single-line height of the round close/send buttons. They stay pinned to the
    /// bottom edge of the (taller) field via the `HStack`'s `.bottom` alignment.
    private let controlHeight: CGFloat = 40

    /// Line range for the growing compose field. Opens at a SINGLE line (`1...`) so it
    /// starts as a compact one-line message box and grows as the user types, up to 14
    /// lines before scrolling. Each added line grows this view's height, which the host
    /// reserves above the toolbar, pushing only the terminal up.
    private let composerLineLimit = 1...14

    /// Minimum height of the compose field, matching the one-line baseline.
    private let composerFieldMinHeight: CGFloat = 40

    private var trimmedIsEmpty: Bool {
        store.terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        composerSurface
        // The field is pinned edge-to-edge inside the surface's composer band, so its
        // outer size is locked to the band height and cannot report its own growth.
        // The field's height is driven solely by its content, so ask the host to
        // re-measure (via `sizeThatFits`, which returns the ideal height independent of
        // the current frame) whenever the text changes — the grow as the user types and
        // the shrink when the field is cleared after a send.
        .onChange(of: store.terminalInputText) { _, _ in
            requestHeightRemeasure()
        }
        .onAppear {
            recordComposerEvent(.composerViewAppear)
            focusField()
        }
        .onDisappear {
            // COMPOSER: logged independently of `isComposerPresented`. A
            // disappear with no matching `composerPresentedChanged a==0` is a
            // view-recreation bug (the flag stayed true but SwiftUI rebuilt the
            // view), not an intentional dismiss.
            recordComposerEvent(.composerViewDisappear)
        }
        .onChange(of: isFieldFocused) { _, focused in
            // COMPOSER: a focus-lost while the flag stayed presented and the
            // view stayed mounted, yet the field reads empty, isolates the
            // residual TextField/@FocusState render-blank case.
            recordComposerEvent(.composerFieldFocusChanged, a: focused ? 1 : 0)
        }
        .onChange(of: store.composerFocusRequest) { _, _ in
            // The surface asked the field to take focus without re-presenting the
            // composer — the reveal-after-hide case, where the chrome and draft are
            // already back but the terminal proxy holds first responder. Driving
            // `@FocusState` here keeps it the single source of truth (the surface
            // never touches the hosted UITextField directly).
            focusField()
        }
    }

    /// Record a composer diagnostic event into the store's structured log (DEBUG
    /// dogfood builds only) so the "Send to agent" feedback pane exports it. A
    /// no-op when no log is wired (release, or a host that does not set it).
    private func recordComposerEvent(_ code: DiagnosticEventCode, a: Int? = nil) {
        #if DEBUG
        store.diagnosticLog?.record(DiagnosticEvent(code, a: a))
        #endif
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
            // Opens at a single line and grows up to 14 lines so a long message has
            // room. Each added line grows this view, which the host reserves above the
            // always-visible toolbar; the toolbar and keyboard never move.
            .lineLimit(composerLineLimit)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($isFieldFocused)
            .foregroundStyle(TerminalPalette.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: composerFieldMinHeight, alignment: .top)
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
