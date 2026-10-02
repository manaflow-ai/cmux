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
        let all = OnboardingModel.Step.allVariants
        #expect(Set(all.map { $0.id }).count == all.count)
        for variant in all {
            #expect(variant.id.hasPrefix(variant.step.rawValue + "."), "\(variant.id)")
            #expect(!variant.name.isEmpty && !variant.summary.isEmpty)
        }
        for step in OnboardingModel.Step.allCases { #expect(!step.variants.isEmpty) }
    }

    @Test func pickFallsBackToTheFirst() {
        #expect(OnboardingModel.Step.theme.chosenVariant(id: "nope").id == OnboardingModel.Step.theme.variants[0].id)
        let last = OnboardingModel.Step.importData.variants.last!
        #expect(OnboardingModel.Step.importData.chosenVariant(id: last.id).id == last.id)
    }

    @Test func everyVariantLaysOut() async {
        for variant in OnboardingModel.Step.allVariants {
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

    @Test func galleryKeysPickNotesAndSummaryPersist() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gallery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GalleryReviewStore(url: url)
        let gallery = OnboardingGalleryController(store: store, makeServices: { _ in self.sample() }, previewAppearance: { _ in })
        // The gallery opens on Role; review starts on Default Browser, after First Task.
        gallery.handle(.nextScreen)
        gallery.handle(.nextScreen)
        gallery.handle(.nextVariant)
        gallery.handle(.nextVariant)
        gallery.handle(.pick)
        gallery.handle(.nextScreen)
        gallery.handle(.jump(0))
        gallery.handle(.pick)
        gallery.handle(.compare)
        gallery.handle(.compare)
        let browser = OnboardingModel.Step.defaultBrowser.variants[2].id
        store.update { $0.notes[browser] = "too much copy" }
        #expect(store.pick(for: .defaultBrowser) == browser)
        #expect(store.pick(for: .importData) == OnboardingModel.Step.importData.variants[0].id)
        let summary = GalleryReviewStore.summary(store.review)
        #expect(summary.hasPrefix("Role: — · First Task: — · Default Browser: C (note: too much copy) · Import: A · Theme: —"))
        // A relaunch finds position, picks and notes.
        let reloaded = GalleryReviewStore(url: url)
        #expect(reloaded.review == store.review)
        #expect(reloaded.review.step == OnboardingModel.Step.importData.rawValue)
        gallery.window?.close()
    }

    @Test func galleryKeyNames() {
        #expect(GalleryKey(name: "right") == .nextVariant && GalleryKey(name: "3") == .jump(2) && GalleryKey(name: "space") == .compare)
        #expect(GalleryKey(name: "0") == nil && GalleryKey(name: "x") == nil)
    }
}
