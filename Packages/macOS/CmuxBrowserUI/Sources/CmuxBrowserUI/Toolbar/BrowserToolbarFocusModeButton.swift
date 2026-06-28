public import SwiftUI

/// The browser focus-mode toolbar button: a keyboard glyph that expands to show
/// the active ("Focus Mode") or armed ("Esc again to exit") label and tints
/// orange while focus mode is active.
///
/// The app-side forwarder overlays the modifier-hold shortcut-hint pill around
/// this button, so this view renders only the button itself.
public struct BrowserToolbarFocusModeButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the focus-mode button from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onFocusMode) {
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                    .scaleEffect(snapshot.isBrowserFocusModeActive ? 1.08 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.82), value: snapshot.isBrowserFocusModeActive)
                if snapshot.isBrowserFocusModeActive {
                    Text(
                        snapshot.isBrowserFocusModeExitArmed
                            ? snapshot.focusModeArmedText
                            : snapshot.focusModeActiveText
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(snapshot.isBrowserFocusModeActive ? Color.orange : snapshot.devToolsTint)
            .padding(.horizontal, snapshot.isBrowserFocusModeActive ? 7 : 0)
            .frame(
                minWidth: snapshot.isBrowserFocusModeActive ? 0 : snapshot.buttonSize,
                minHeight: snapshot.buttonSize,
                alignment: .center
            )
            .animation(.easeOut(duration: 0.14), value: snapshot.isBrowserFocusModeActive)
            .animation(.easeOut(duration: 0.12), value: snapshot.isBrowserFocusModeExitArmed)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(height: snapshot.buttonSize, alignment: .center)
        .disabled(!snapshot.canToggleBrowserFocusMode)
        .opacity(snapshot.canToggleBrowserFocusMode ? 1.0 : 0.4)
        .safeHelp(snapshot.focusModeHelp)
        .accessibilityIdentifier("BrowserFocusModeButton")
    }
}
