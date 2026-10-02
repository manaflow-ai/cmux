import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Every screen variant: a unique id under its step, and it lays out in the
/// fixed window with sample data (no layout loop, the window keeps its size).
@MainActor
@Suite struct VariantRegistryTests {
    func sample() -> MockOnboardingServices {
        MockOnboardingServices.gallerySample(themes: (0..<9).map { ThemeChoice(name: "Theme \($0)", input: .ghosttyDefault) },
                                             accountsView: NSView())
    }

    @Test func idsAreUniqueAndNamedByStep() {
        let all = OnboardingVariantRegistry.all
        #expect(Set(all.map { $0.id }).count == all.count)
        for variant in all {
            #expect(variant.id.hasPrefix(variant.step.rawValue + "."), "\(variant.id)")
            #expect(!variant.name.isEmpty && !variant.summary.isEmpty)
        }
        for step in OnboardingModel.Step.allCases { #expect(!OnboardingVariantRegistry.variants(for: step).isEmpty) }
    }

    @Test func pickFallsBackToTheFirst() {
        #expect(OnboardingVariantRegistry.chosen(for: .theme, id: "nope").id == OnboardingVariantRegistry.variants(for: .theme)[0].id)
        let last = OnboardingVariantRegistry.variants(for: .importData).last!
        #expect(OnboardingVariantRegistry.chosen(for: .importData, id: last.id).id == last.id)
    }

    @Test func everyVariantLaysOut() async {
        for variant in OnboardingVariantRegistry.all {
            let services = sample()
            let model = OnboardingModel(services: services, start: variant.step)
            let controller = OnboardingWindowController(model: model, variant: variant)
            guard let window = controller.window else { continue }
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            model.stepDidAppear()
            for _ in 0..<30 { await Task.yield() }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(window.contentView?.frame.size == OnboardingMetrics.windowSize, "\(variant.id)")
            if let content = window.contentView {
                let ambiguous = Self.ambiguousViews(content)
                #expect(ambiguous.isEmpty, "\(variant.id): ambiguous layout in \(ambiguous)")
            }
            window.close()
        }
    }

    /// Views of ours whose Auto Layout is ambiguous (AppKit's own control internals are skipped).
    static func ambiguousViews(_ view: NSView) -> [String] {
        var found: [String] = []
        let ours = String(reflecting: type(of: view)).hasPrefix("CmuxNextOnboarding")
        // A scroll document is placed by its clip view, not by constraints.
        let document = view.superview is NSClipView
        if ours, !document, !view.translatesAutoresizingMaskIntoConstraints, view.hasAmbiguousLayout { found.append(String(describing: type(of: view))) }
        for child in view.subviews { found += ambiguousViews(child) }
        return found
    }

    @Test func galleryBuildsEveryTileAndStoresPicks() {
        let picks = MockOnboardingServices()
        let gallery = OnboardingGalleryController(picks: picks, makeServices: { self.sample() }, previewFlow: {})
        let variant = OnboardingVariantRegistry.variants(for: .theme).last!
        gallery.use(variant)
        #expect(picks.variantIDs[.theme] == variant.id)
        gallery.window?.close()
    }
}
