public import AppKit
import CmuxNextDesign
import SwiftUI

/// Add Machine and Check Machine (plans/cmux-next/add-machine-DESIGN.md): one model and one
/// floating card, made once and kept, so a run in flight survives the card closing and a reopen
/// shows it again. The App supplies the services (the CLI, the install path, connect).
@MainActor
public final class AddMachineCard {
    public let model: AddMachineModel
    private var panel: AddMachineCardPanel?

    public init(services: AddMachineServices) {
        model = AddMachineModel(services: services)
    }

    /// Opens Add Machine over `window`. A destination (the CLI, MCP, a script) only fills the field:
    /// the add starts when the person presses Add. The card takes the keys for its field.
    public func open(destination: String? = nil, name: String? = nil, over window: NSWindow?) {
        model.begin(destination: destination, name: name)
        present(over: window)
    }

    /// Opens Check Machine for an SSH machine the app has and runs doctor.
    public func check(host: String, machineID: String, over window: NSWindow?) {
        model.beginCheck(host: host, machineID: machineID)
        present(over: window)
    }

    /// Opens Check for a machine that joined with a one-line token and runs `machine doctor ID`.
    public func checkJoined(id: String, name: String, rowID: String? = nil, over window: NSWindow?) {
        model.beginJoinedCheck(id: id, name: name, rowID: rowID)
        present(over: window)
    }

    /// Nil once the run in flight ended ready, else why not.
    public func finished() async -> String? {
        await model.finished()
    }

    public var isShown: Bool { panel?.isVisible == true }

    private func present(over window: NSWindow?) {
        let panel = panel ?? AddMachineCardPanel(model: model)
        self.panel = panel
        panel.present(over: window)
    }
}

/// The card's panel: the Add Server card's floating glass (``AddServerCardPanel``), near the top
/// center of the cmux window, on every Space and over full screen, never activating the app. It
/// takes the keys (Add Machine is always opened by hand); Return and Escape run the footer's buttons.
@MainActor
final class AddMachineCardPanel: NSPanel {
    let model: AddMachineModel
    private let host: AddMachineHostView

    init(model: AddMachineModel) {
        self.model = model
        host = AddMachineHostView(model: model)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: ServerMetrics.cardWidth, height: 200)),
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
        setAccessibilityIdentifier("cmux.addMachineCard")
        host.autoresizingMask = [.width, .height]
        contentView = host
        host.onDismiss = { [weak self] in self?.orderOut(nil) }
        host.onContentSize = { [weak self] size in self?.fit(size) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(over window: NSWindow?) {
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        let size = host.fittingSize
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(AddServerCardPanel.placement(size: size, over: window?.frame, in: visible), display: false)
        WindowActivation.show(self, .raise)
    }

    /// Escape while the card has the keys: the same as Cancel (a run stops) or Done.
    override func cancelOperation(_ sender: Any?) {
        let escape = model.buttons.first { $0.key == .escape }?.action ?? .done
        if model.perform(escape) { orderOut(nil) }
    }

    /// Grow or shrink downward as the steps fill in, keeping the top edge where the user saw it.
    private func fit(_ size: NSSize) {
        guard size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}

/// Hosts ``AddMachineView`` on the server surfaces' material (``ServerHostView``): Liquid Glass on
/// macOS 26, a tinted blur before, opaque under Reduce Transparency, colors resolved in this view's
/// theme scope and again on every theme change.
@MainActor
final class AddMachineHostView: NSView {
    var onDismiss: (() -> Void)? {
        didSet { dismissBox.action = onDismiss }
    }
    var onContentSize: ((CGSize) -> Void)? {
        didSet { dismissBox.resized = onContentSize }
    }

    private let appearanceState = ServerAppearance()
    private let dismissBox = DismissBox()
    private let backdrop: OverlaySurfaceView
    private let wash = NSView()

    /// `material` pins the backdrop (tests, screenshots); nil follows this Mac.
    init(model: AddMachineModel, material: OverlayMaterial? = nil) {
        backdrop = OverlaySurfaceView(material: material)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [backdrop, wash] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        backdrop.cornerRadius = ServerMetrics.cornerRadius
        wash.wantsLayer = true
        wash.layer?.cornerRadius = ServerMetrics.cornerRadius
        wash.layer?.cornerCurve = .continuous
        let dismiss = dismissBox
        let hosting = NSHostingView(rootView: AddMachineRoot(model: model, appearance: appearanceState, dismiss: dismiss))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        resolveColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            let base = Palette.windowBackground.usingColorSpace(.sRGB) ?? Palette.windowBackground
            wash.layer?.backgroundColor = base.withAlphaComponent(backdrop.material == .opaque ? 0 : Self.washAlpha).cgColor
            return ServerColors.resolved()
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
        backdrop.applyTheme()
    }

    private static let washAlpha: CGFloat = 0.78
}

/// Reads the resolved colors in a tracked scope, so a theme change updates the card live.
struct AddMachineRoot: View {
    let model: AddMachineModel
    let appearance: ServerAppearance
    let dismiss: DismissBox

    var body: some View {
        AddMachineView(model: model, close: { dismiss.action?() }, resized: { dismiss.resized?($0) })
            .environment(\.serverColors, appearance.colors)
            .environment(\.serverLineWidth, Borders.current.width(1))
            .focusEffectDisabled()
    }
}
