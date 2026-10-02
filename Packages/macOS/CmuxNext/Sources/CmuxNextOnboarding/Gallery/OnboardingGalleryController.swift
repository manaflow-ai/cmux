public import AppKit
import CmuxNextDesign

/// The onboarding gallery (DEBUG tool): every screen as a row, each with a
/// grid of its variants rendered live at a uniform scale. Open shows one
/// full size; Use This stores it as the flow's pick for that screen;
/// Preview Flow runs the real onboarding with the picks.
public final class OnboardingGalleryController: NSWindowController, NSWindowDelegate {
    /// Fresh sample services per thumbnail and preview: sample browsers and
    /// themes, no settings writes; the accounts view is the real one (the
    /// thumbnails are inert, a full-size preview acts on real accounts).
    private let makeServices: @MainActor () -> any OnboardingServices
    private let picks: any OnboardingServices
    private let previewFlow: () -> Void
    private var rows: [OnboardingGalleryRow] = []
    private var previews: [OnboardingWindowController] = []
    public var onClose: (() -> Void)?

    /// `picks` stores the chosen variants (the app's services); `makeServices`
    /// gives sample data for the thumbnails and full-size previews.
    public init(picks: any OnboardingServices, makeServices: @escaping @MainActor () -> any OnboardingServices, previewFlow: @escaping () -> Void) {
        self.makeServices = makeServices
        self.picks = picks
        self.previewFlow = previewFlow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Onboarding Gallery"
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding.gallery")
        window.backgroundColor = Palette.windowBackground
        ThemeStore.shared.adopt(window)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        guard let window else { return }
        WindowPlacement.present(window)
    }

    /// Opens one variant full size with sample data; returns its window.
    @discardableResult
    public func openFullSize(_ variant: any OnboardingScreenVariant.Type) -> NSWindow? {
        let model = OnboardingModel(services: makeServices(), start: variant.step)
        let controller = OnboardingWindowController(model: model, variant: variant)
        controller.onClose = { [weak self, weak controller] in self?.previews.removeAll { $0 === controller } }
        previews.append(controller)
        controller.present()
        return controller.window
    }

    /// Stores `variant` as the flow's pick for its screen.
    public func use(_ variant: any OnboardingScreenVariant.Type) {
        picks.setVariantID(variant.id, for: variant.step)
        for row in rows { row.refreshPicks() }
    }

    /// Scrolls the row of `step` to the top of the window (screenshots, debug.onboarding).
    public func scroll(to step: OnboardingModel.Step) {
        guard let row = rows.first(where: { $0.step == step }), let clip = row.enclosingScrollView?.contentView else { return }
        let origin = row.convert(NSPoint(x: 0, y: -12), to: clip.documentView)
        clip.scroll(to: NSPoint(x: 0, y: max(0, origin.y)))
        row.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    public func windowWillClose(_ notification: Notification) {
        for preview in previews { preview.close() }
        onClose?()
    }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 32
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 32, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let preview = OnboardingControl.button("Preview Flow", prominent: true, target: self, action: #selector(previewPressed))
        let header = NSStackView(views: [OnboardingLabel.make("Pick one design per screen. Preview Flow runs the real onboarding with your picks.", color: Palette.textSecondary),
                                         preview])
        header.spacing = 16
        stack.addArrangedSubview(header)
        for step in OnboardingModel.Step.allCases {
            let row = OnboardingGalleryRow(step: step, gallery: self, picks: picks, makeServices: makeServices)
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return scroll
    }

    @objc private func previewPressed() { previewFlow() }
}
