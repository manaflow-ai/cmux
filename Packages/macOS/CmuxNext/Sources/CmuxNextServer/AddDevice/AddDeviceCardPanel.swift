public import AppKit
import CmuxNextDesign

/// The Add Device card's panel: the same floating glass card as Add Server and Add Machine
/// (``AddServerCardPanel``), near the top center of the cmux window, on every Space and over full
/// screen, never activating the app. Escape runs the card's Cancel.
@MainActor
final class AddDeviceCardPanel: NSPanel {
    let model: AddDeviceModel
    let content: AddDeviceView
    private let glass: GlassPanelView

    init(model: AddDeviceModel) {
        self.model = model
        content = AddDeviceView(model: model)
        glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 14)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: AddDeviceView.width, height: 240)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.addDeviceCard")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        content.onClose = { [weak self] in self?.orderOut(nil) }
        content.onResize = { [weak self] size in self?.fit(size) }
    }

    override var canBecomeKey: Bool { true }

    /// The card got the focus (the person came back from the new machine's terminal): the one-line
    /// join reads the machine list once (``MachineJoinLineModel/refresh()``); nothing polls it.
    override func becomeKey() {
        super.becomeKey()
        guard let join = model.joinLine, join.line != nil else { return }
        // task-owner: one list read per focus; the model drops it once the line is gone.
        Task { await join.refresh() }
    }
    override var canBecomeMain: Bool { false }

    /// Shows the card over `window` and gives it the keys (Add Device is always opened by a person).
    func present(over window: NSWindow?) {
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        let size = content.fittingSize
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(AddServerCardPanel.placement(size: size, over: window?.frame, in: visible), display: false)
        WindowActivation.show(self, .raise)
    }

    override func cancelOperation(_ sender: Any?) {
        if model.perform(.cancel) { orderOut(nil) }
    }

    /// Grows or shrinks downward, keeping the top edge where the person saw it.
    private func fit(_ size: NSSize) {
        guard size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
