import AppKit
import SwiftUI

/// A compact titlebar control that toggles the right sidebar through the app's
/// shared window-routing action.
struct RightSidebarTitlebarToggleView: View {
    let action: () -> Void

    @AppStorage(TitlebarControlsStyle.storageKey)
    private var titlebarControlsStyleRawValue = TitlebarControlsStyle.defaultRawValue

    private var config: TitlebarControlsStyleConfig {
        TitlebarControlsStyle.stored(rawValue: titlebarControlsStyleRawValue).config
    }

    var body: some View {
        TitlebarControlButton(
            config: config,
            foregroundColor: Color(nsColor: titlebarControlForegroundNSColor(opacity: 1.0)),
            accessibilityIdentifier: "titlebarControl.toggleRightSidebar",
            accessibilityLabel: KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            action: action
        ) {
            SidebarGlyph(iconSize: config.iconSize, side: .trailing)
        }
        .safeHelp(
            KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
            )
        )
    }
}

/// Hosts the persistent right-sidebar toggle in an AppKit titlebar accessory.
@MainActor
final class RightSidebarTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.rightSidebarTitlebarToggle")

    private let containerView: TitlebarAccessoryContainerView
    private let hostingView: NonDraggableHostingView<AnyView>

    /// Creates the titlebar host and wires its action to the active main window.
    init() {
        let containerView = TitlebarAccessoryContainerView()
        self.containerView = containerView
        self.hostingView = NonDraggableHostingView(
            rootView: AnyView(
                RightSidebarTitlebarToggleView(
                    action: { [weak containerView] in
                        guard let window = containerView?.window else { return }
                        #if DEBUG
                        cmuxDebugLog("titlebar.toggleRightSidebar")
                        #endif
                        _ = AppDelegate.shared?.toggleRightSidebarInActiveMainWindow(
                            preferredWindow: window
                        )
                    }
                )
                .frame(
                    width: HeaderChromeControlMetrics.buttonSize + 10,
                    height: WindowChromeMetrics.appTitlebarHeight,
                    alignment: .center
                )
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        view.identifier = Self.identifier
        containerView.translatesAutoresizingMaskIntoConstraints = true
        containerView.wantsLayer = true
        containerView.clipsToBounds = false
        containerView.layer?.masksToBounds = false

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.clipsToBounds = false
        hostingView.layer?.masksToBounds = false
        containerView.addSubview(hostingView)

        preferredContentSize = Self.preferredSize
        hostingView.frame = containerView.bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keeps the SwiftUI host aligned with AppKit's accessory container.
    override func viewDidLayout() {
        super.viewDidLayout()
        hostingView.frame = containerView.bounds
    }

    private static let preferredSize = NSSize(
        width: HeaderChromeControlMetrics.buttonSize + 10,
        height: WindowChromeMetrics.appTitlebarHeight
    )
}
