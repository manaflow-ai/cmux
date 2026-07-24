import AppKit
import CmuxCommandPalette
import ObjectiveC
import SwiftUI

let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier(
    "cmux.commandPalette.overlay.container"
)

private var commandPaletteWindowPanelKey: UInt8 = 0

struct CommandPalettePanelLayout: Equatable {
    let width: CGFloat
    let workspaceDescriptionMaximumEditorHeight: CGFloat
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the command palette's native window lifecycle for one main cmux window.
/// The palette's semantic/search state stays in `ContentView`; this controller
/// owns only presentation, stacking, placement, and key-window dismissal.
@MainActor
final class WindowCommandPalettePanelController: NSObject {
    private weak var ownerWindow: NSWindow?
    private let panel: CommandPalettePanel
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let interactionMonitor = CommandPaletteInteractionMonitor()
    private var ownerObserverTokens: [any NSObjectProtocol] = []
    private var isPaletteVisible = false
    private var onDismiss: ((CommandPaletteInteractionDismissal) -> Void)?
    private var onDidBecomeKey: (() -> Void)?
    private var layout = CommandPalettePanelLayout(
        width: 560,
        workspaceDescriptionMaximumEditorHeight: 380
    )
    private var lastContentHeight: CGFloat = 490

    init(ownerWindow: NSWindow) {
        self.ownerWindow = ownerWindow
        panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 490),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.identifier = NSUserInterfaceItemIdentifier(
            "cmux.commandPalette.panel.\(ownerWindow.windowNumber)"
        )
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        // The palette owns an instant show/hide lifecycle. AppKit's utility
        // window behavior adds a second fade after the user presses Escape.
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.contentView = hostingView

        hostingView.identifier = commandPaletteOverlayContainerIdentifier
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let center = NotificationCenter.default
        ownerObserverTokens = [
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: ownerWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionPanel() }
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: ownerWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionPanel() }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDidBecomeKey?() }
            },
        ]
    }

    deinit {
        MainActor.assumeIsolated {
            interactionMonitor.deactivate()
            for token in ownerObserverTokens {
                NotificationCenter.default.removeObserver(token)
            }
            if let ownerWindow, panel.parent === ownerWindow {
                ownerWindow.removeChildWindow(panel)
            }
            panel.orderOut(nil)
        }
    }

    var presentedWindow: NSWindow? {
        isPaletteVisible && panel.isVisible ? panel : nil
    }

    func update(
        isVisible: Bool,
        onDismiss: @escaping (CommandPaletteInteractionDismissal) -> Void,
        onDidBecomeKey: @escaping () -> Void,
        makeRootView: (
            CommandPalettePanelLayout,
            @escaping (CGSize) -> Void
        ) -> AnyView
    ) {
        guard let ownerWindow else {
            hidePanel()
            return
        }
        guard isVisible else {
            hidePanel()
            return
        }

        let wasVisible = isPaletteVisible
        isPaletteVisible = true
        self.onDismiss = onDismiss
        self.onDidBecomeKey = onDidBecomeKey
        layout = Self.layout(for: ownerWindow)
        hostingView.rootView = makeRootView(layout) { [weak self] size in
            self?.contentSizeDidChange(size)
        }
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        if fittingSize.height.isFinite, fittingSize.height > 1 {
            lastContentHeight = fittingSize.height
        }
        repositionPanel()

        if panel.parent !== ownerWindow {
            ownerWindow.addChildWindow(panel, ordered: .above)
        } else if !wasVisible {
            ownerWindow.removeChildWindow(panel)
            ownerWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)

        interactionMonitor.activate(
            for: panel,
            shouldDismiss: { event in
                event.shouldDismissPalette(panelContainsPoint: event.isInObservedWindow)
            },
            onWindowStateChange: {},
            onDismiss: { [weak self] dismissal in
                self?.dismissFromInteraction(dismissal)
            }
        )

        if !wasVisible || !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private static func layout(for ownerWindow: NSWindow) -> CommandPalettePanelLayout {
        let contentWidth = ownerWindow.contentLayoutRect.width
        let contentHeight = ownerWindow.contentLayoutRect.height
        return CommandPalettePanelLayout(
            width: min(560, max(340, contentWidth - 260)),
            workspaceDescriptionMaximumEditorHeight: max(
                80,
                contentHeight - 120
            )
        )
    }

    private func contentSizeDidChange(_ size: CGSize) {
        guard isPaletteVisible,
              size.height.isFinite,
              size.height > 1 else { return }
        let nextHeight = ceil(size.height)
        guard abs(nextHeight - lastContentHeight) >= 0.5 else { return }
        lastContentHeight = nextHeight
        repositionPanel()
    }

    private func repositionPanel() {
        guard isPaletteVisible,
              let ownerWindow,
              let screen = ownerWindow.screen ?? NSScreen.main else { return }
        let contentSize = CGSize(width: layout.width, height: lastContentHeight)
        let placement = CommandPalettePanelPlacement(
            ownerFrame: ownerWindow.frame,
            visibleFrame: screen.visibleFrame,
            contentSize: contentSize
        )
        panel.setFrame(placement.frame, display: panel.isVisible)
    }

    private func dismissFromInteraction(_ dismissal: CommandPaletteInteractionDismissal) {
        guard isPaletteVisible else { return }
        let callback = onDismiss
        hidePanel()
        callback?(dismissal)
    }

    private func hidePanel() {
        guard isPaletteVisible || panel.isVisible else { return }
        interactionMonitor.deactivate()
        isPaletteVisible = false
        onDismiss = nil
        onDidBecomeKey = nil
        if panel.firstResponder != nil {
            _ = panel.makeFirstResponder(nil)
        }
        panel.orderOut(nil)
        if let ownerWindow, panel.parent === ownerWindow {
            ownerWindow.removeChildWindow(panel)
        }
    }
}

@MainActor
func commandPaletteWindowPanelController(for window: NSWindow) -> WindowCommandPalettePanelController {
    if let existing = objc_getAssociatedObject(
        window,
        &commandPaletteWindowPanelKey
    ) as? WindowCommandPalettePanelController {
        return existing
    }
    let controller = WindowCommandPalettePanelController(ownerWindow: window)
    objc_setAssociatedObject(
        window,
        &commandPaletteWindowPanelKey,
        controller,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return controller
}

@MainActor
func commandPalettePresentedPanelWindow(for ownerWindow: NSWindow) -> NSWindow? {
    (objc_getAssociatedObject(
        ownerWindow,
        &commandPaletteWindowPanelKey
    ) as? WindowCommandPalettePanelController)?.presentedWindow
}
