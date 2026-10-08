import AppKit
import CmuxNextDesign

extension OnboardingGalleryController {
    static let barHeight: CGFloat = 88
    static let stageMargin: CGFloat = 40

    func makeContent() -> NSView {
        let root = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        let barLine = NSBox()
        barLine.boxType = .separator
        for view in [sidebarView, divider, stageView, barLine, barView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebarView.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: barLine.topAnchor), sidebarView.widthAnchor.constraint(equalToConstant: 220),
            divider.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: barLine.topAnchor),
            stageView.leadingAnchor.constraint(equalTo: divider.trailingAnchor), stageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stageView.topAnchor.constraint(equalTo: root.topAnchor), stageView.bottomAnchor.constraint(equalTo: barLine.topAnchor),
            barLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), barLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barLine.bottomAnchor.constraint(equalTo: barView.topAnchor),
            barView.leadingAnchor.constraint(equalTo: root.leadingAnchor), barView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            barView.heightAnchor.constraint(equalToConstant: Self.barHeight),
            // The stage always fits one screen at real size, so Auto Layout
            // never shrinks the window around the bar.
            stageView.widthAnchor.constraint(greaterThanOrEqualToConstant: OnboardingMetrics.windowSize.width + 2 * Self.stageMargin),
            stageView.heightAnchor.constraint(greaterThanOrEqualToConstant: OnboardingMetrics.windowSize.height + 2 * Self.stageMargin),
        ])
        return root
    }

    func render() {
        sidebarView.render(current: step, review: store.review)
        if isComparing, let pinnedID = store.review.pinned[step.rawValue],
           let pinnedIndex = variants.firstIndex(where: { $0.id == pinnedID }) {
            stageView.compare((variant, letter(index)), (variants[pinnedIndex], letter(pinnedIndex) + " (pinned)"),
                              services: { [unowned self] in sampleServices() })
        } else {
            stageView.show(variant, letter: letter(index), services: sampleServices())
        }
        renderBar()
    }

    func renderBar() {
        let picked = store.pick(for: step) == variant.id
        barView.label.stringValue = runningFlowLabel ?? "\(step.galleryName) · \(letter(index))  \(variant.name)\(picked ? "  ✓ picked" : "")"
        barView.detail.stringValue = "\(index + 1) of \(variants.count) · \(variant.summary) · \(variant.surface.rawValue), \(variant.transition.rawValue)"
        if barView.window?.firstResponder !== barView.note.currentEditor() { barView.note.stringValue = store.review.notes[variant.id] ?? "" }
        barView.pick.title = picked ? "Picked" : "Pick (P)"
        barView.compare.title = isComparing ? "Single (Space)" : "Compare (Space)"
    }

    func letter(_ index: Int) -> String { index.galleryLetter }
}
