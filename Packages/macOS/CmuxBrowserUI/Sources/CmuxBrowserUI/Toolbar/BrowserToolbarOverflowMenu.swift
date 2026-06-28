public import SwiftUI

/// Overflow menu shown in compact chrome: the plain-action accessory buttons
/// (focus mode, screenshot, React Grab, dev tools) collapsed into menu items.
/// Profile and theme stay as visible buttons app-side since they anchor
/// popovers.
public struct BrowserToolbarOverflowMenu: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the overflow menu from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Menu {
            Button(action: actions.onFocusMode) {
                Label(
                    snapshot.isBrowserFocusModeActive
                        ? snapshot.focusModeActiveText
                        : snapshot.focusModeEnterText,
                    systemImage: "keyboard"
                )
            }
            .disabled(!snapshot.canToggleBrowserFocusMode)

            Button(action: actions.onScreenshot) {
                Label(
                    snapshot.screenshotCopyHelp,
                    systemImage: "camera"
                )
            }
            .disabled(!snapshot.shouldRenderWebView)

            Button(action: actions.onReactGrabFromOverflow) {
                Label(
                    snapshot.reactGrabText,
                    systemImage: "cursorarrow.click.2"
                )
            }

            Button(action: actions.onDevTools) {
                Label(snapshot.devToolsHelp, systemImage: snapshot.devToolsIconName)
            }
        } label: {
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: snapshot.accessoryIconFontSize, weight: .medium))
                .foregroundStyle(snapshot.devToolsTint)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        .safeHelp(snapshot.moreActionsHelp)
        .accessibilityIdentifier("BrowserOverflowMenu")
    }
}
