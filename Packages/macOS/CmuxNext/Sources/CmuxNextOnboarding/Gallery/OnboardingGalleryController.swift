public import AppKit
import CmuxNextDesign

/// The onboarding gallery (DEBUG review tool), one window: screens on the
/// left, the current screen's variants one at a time at real size in the
/// center (or two side by side in Compare), and a bottom bar with the
/// variant's letter, a note, Pick, Copy Feedback and Run Flow. Keyboard
/// first; position, picks and notes persist in `GalleryReviewStore`.
public final class OnboardingGalleryController: NSWindowController, NSWindowDelegate {
    public let store: GalleryReviewStore
    /// Fresh sample services (sample browsers and themes; the flow's picks
    /// come from the store). No settings writes.
    private let makeServices: @MainActor (GalleryReviewStore) -> any OnboardingServices
    /// Switches the app's theme preview: true dark, false light, nil back to normal.
    private let previewAppearance: (Bool?) -> Void
    let sidebarView = GallerySidebar()
    let stageView = GalleryStage()
    /// Built in init where `onNote` is set (no IUO; lazy because its targets are self).
    lazy var barView = GalleryBottomBar(target: self, pick: #selector(pickPressed), compare: #selector(comparePressed),
                                        copy: #selector(copyPressed), run: #selector(runPressed))
    private(set) var isComparing = false
    private var runningFlow = false {
        didSet { (window as? GalleryWindow)?.flowRunning = runningFlow }
    }
    var runningFlowLabel: String? { runningFlow ? "Running the flow with your picks · Esc returns" : nil }
    public var onClose: (() -> Void)?

    public init(store: GalleryReviewStore, makeServices: @escaping @MainActor (GalleryReviewStore) -> any OnboardingServices,
                previewAppearance: @escaping (Bool?) -> Void) {
        self.store = store
        self.makeServices = makeServices
        self.previewAppearance = previewAppearance
        let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Onboarding Review"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 700)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding.gallery")
        super.init(window: window)
        window.delegate = self
        barView.onNote = { [weak self] text in self?.setNote(text) }
        sidebarView.onSelect = { [weak self] step in self?.go(step: step, index: 0) }
        window.install(kind: .onboardingGallery, content: makeContent(), scope: .app)
        (window as GalleryWindow).onKey = { [weak self] key in self?.handle(key) ?? false }
        if let dark = store.review.darkPreview { previewAppearance(dark) }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        guard let window else { return }
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        previewAppearance(nil)
        onClose?()
    }

    // MARK: State

    var step: OnboardingModel.Step { OnboardingModel.Step(rawValue: store.review.step) ?? OnboardingModel.Step.allCases[0] }
    var variants: [any OnboardingScreenVariant.Type] { step.variants }
    var index: Int { min(max(store.review.index, 0), variants.count - 1) }
    var variant: any OnboardingScreenVariant.Type { variants[index] }

    public func go(step: OnboardingModel.Step, index: Int) {
        runningFlow = false
        store.update {
            $0.step = step.rawValue
            $0.index = index
        }
        render()
    }

    /// The keys, also reachable over the debug socket (`debug.onboarding gallery_key`).
    @discardableResult
    public func handle(_ key: GalleryKey) -> Bool {
        let steps = OnboardingModel.Step.allCases
        let stepIndex = steps.firstIndex(of: step) ?? 0
        switch key {
        case .previousVariant: go(step: step, index: (index - 1 + variants.count) % variants.count)
        case .nextVariant: go(step: step, index: (index + 1) % variants.count)
        case .previousScreen: go(step: steps[(stepIndex - 1 + steps.count) % steps.count], index: 0)
        case .nextScreen: go(step: steps[(stepIndex + 1) % steps.count], index: 0)
        case .jump(let number): if number < variants.count { go(step: step, index: number) }
        case .pick: pick()
        case .compare: toggleCompare()
        case .appearance: toggleAppearance()
        case .runFlow: runFlow()
        case .copy: copyFeedback()
        case .close: if runningFlow { go(step: step, index: index) } else { window?.close() }
        }
        return true
    }

    private func pick() {
        // Read before the update: the closure holds the review exclusively.
        let (key, id) = (step.rawValue, variant.id)
        store.update { $0.picks[key] = id }
        render()
    }

    private func toggleCompare() {
        if isComparing {
            isComparing = false
        } else {
            // Compare the current variant with the pinned one (else the pick, else the next).
            let key = step.rawValue
            let next = variants[(index + 1) % variants.count].id
            let other = store.review.pinned[key] ?? store.pick(for: step) ?? next
            let pinned = other == variant.id && variants.count > 1 ? next : other
            store.update { $0.pinned[key] = pinned }
            isComparing = true
        }
        render()
    }

    private func toggleAppearance() {
        let dark = !(store.review.darkPreview ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
        store.update { $0.darkPreview = dark }
        previewAppearance(dark)
        render()
    }

    private func runFlow() {
        runningFlow = true
        isComparing = false
        stageView.runFlow(services: makeServices(store)) { [weak self] in
            guard let self else { return }
            go(step: step, index: index)
        }
        renderBar()
    }

    private func setNote(_ text: String) {
        let id = variant.id
        store.update { $0.notes[id] = text }
    }

    /// Copies the compact summary ("Theme: C (note: …) · Import: A …").
    public func copyFeedback() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GalleryReviewStore.summary(store.review), forType: .string)
        barView.detail.stringValue = "Feedback copied. Also saved to \(store.url.path)"
    }

    func sampleServices() -> any OnboardingServices { makeServices(store) }

    @objc private func pickPressed() { pick() }
    @objc private func comparePressed() { toggleCompare() }
    @objc private func copyPressed() { copyFeedback() }
    @objc private func runPressed() { runFlow() }
}
