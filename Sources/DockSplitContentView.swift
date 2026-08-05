import AppKit
import Bonsplit
import CmuxAppKitSupportUI

@MainActor
final class DockSplitPresentationContext {
    let store: DockSplitStore
    var appearance: PanelAppearance
    var appearanceRevision: UInt
    var windowAppearance: WindowAppearanceSnapshot
    var rightSidebarOwnsInputFocus: Bool
    var unreadPanelIDs: Set<UUID>

    init(
        store: DockSplitStore,
        appearance: PanelAppearance,
        appearanceRevision: UInt,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool,
        unreadPanelIDs: Set<UUID>
    ) {
        self.store = store
        self.appearance = appearance
        self.appearanceRevision = appearanceRevision
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        self.unreadPanelIDs = unreadPanelIDs
    }
}

/// Native owner for the Dock's Bonsplit tree. Bonsplit retains one controller
/// per tab, while ``DockSplitPanelContentHostingController`` owns each native
/// panel leaf.
@MainActor
final class DockSplitViewController: NSViewController {
    private let context: DockSplitPresentationContext
    private let bonsplitViewController: BonsplitViewController

    init(
        store: DockSplitStore,
        appearance: PanelAppearance,
        appearanceRevision: UInt,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool,
        unreadPanelIDs: Set<UUID>
    ) {
        let context = DockSplitPresentationContext(
            store: store,
            appearance: appearance,
            appearanceRevision: appearanceRevision,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
            unreadPanelIDs: unreadPanelIDs
        )
        self.context = context
        self.bonsplitViewController = BonsplitViewController(
            controller: store.bonsplitController,
            content: { tab, paneID in
                DockSplitPanelContentHostingController(
                    context: context,
                    tab: tab,
                    paneID: paneID
                )
            },
            emptyPane: { paneID in
                DockEmptyPaneViewController(
                    onFocus: { store.bonsplitController.focusPane(paneID) },
                    onNewTerminal: {
                        _ = store.newSurface(kind: .terminal, inPane: paneID, focus: true)
                    },
                    onNewBrowser: {
                        _ = store.newSurface(kind: .browser, inPane: paneID, focus: true)
                    }
                )
            }
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        addChild(bonsplitViewController)
        let splitView = bonsplitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateBackground()
    }

    func update(
        appearance: PanelAppearance,
        appearanceRevision: UInt,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool,
        unreadPanelIDs: Set<UUID>
    ) {
        context.appearance = appearance
        context.appearanceRevision = appearanceRevision
        context.windowAppearance = windowAppearance
        context.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        context.unreadPanelIDs = unreadPanelIDs
        updateBackground()
        bonsplitViewController.refreshContent()
    }

    private func updateBackground() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = context.appearance.backgroundColor.cgColor
    }
}

@MainActor
private final class DockEmptyPaneViewController: NSViewController {
    private let onFocus: () -> Void
    private let onNewTerminal: () -> Void
    private let onNewBrowser: () -> Void

    init(
        onFocus: @escaping () -> Void,
        onNewTerminal: @escaping () -> Void,
        onNewBrowser: @escaping () -> Void
    ) {
        self.onFocus = onFocus
        self.onNewTerminal = onNewTerminal
        self.onNewBrowser = onNewBrowser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let image = NSImageView(image: NSImage(
            systemSymbolName: "dock.rectangle",
            accessibilityDescription: nil
        ) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        image.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: String(
            localized: "dock.emptyPane.title",
            defaultValue: "Empty Dock Pane"
        ))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let terminalButton = NSButton(
            title: String(localized: "dock.action.newTerminal", defaultValue: "New Terminal"),
            target: self,
            action: #selector(createTerminal(_:))
        )
        terminalButton.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
        terminalButton.controlSize = .small
        let browserButton = NSButton(
            title: String(localized: "dock.action.newBrowser", defaultValue: "New Browser"),
            target: self,
            action: #selector(createBrowser(_:))
        )
        browserButton.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        browserButton.controlSize = .small
        let buttons = NSStackView(views: [terminalButton, browserButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [image, title, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusPane(_:))))
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            image.widthAnchor.constraint(equalToConstant: 34),
            image.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = root
    }

    @objc private func focusPane(_ sender: NSClickGestureRecognizer) {
        onFocus()
    }

    @objc private func createTerminal(_ sender: NSButton) {
        onNewTerminal()
    }

    @objc private func createBrowser(_ sender: NSButton) {
        onNewBrowser()
    }
}
