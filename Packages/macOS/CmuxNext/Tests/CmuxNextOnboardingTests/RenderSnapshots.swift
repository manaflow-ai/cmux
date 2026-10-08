import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Writes PNGs of the gallery and every variant (layout review without an
/// app build). Runs only with `CMUX_ONBOARDING_RENDER_DIR=<dir>`. Liquid
/// Glass does not draw into these bitmaps; the tagged build shows it.
@MainActor
@Suite struct RenderSnapshots {
    nonisolated static let directory = ProcessInfo.processInfo.environment["CMUX_ONBOARDING_RENDER_DIR"]

    func write(_ view: NSView, _ name: String) {
        guard let directory = Self.directory, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appending(path: name + ".png"))
    }

    func sample() -> MockOnboardingServices {
        MockOnboardingServices.gallerySample(themes: (0..<9).map { ThemeChoice(name: "Theme \($0)", input: .ghosttyDefault) },
                                             accountsView: NSView())
    }

    @Test(.enabled(if: directory != nil)) func renderEverything() async {
        for variant in OnboardingModel.Step.allVariants {
            let model = OnboardingModel(services: sample(), start: variant.step)
            let controller = OnboardingWindowController(model: model, variant: variant)
            guard let window = controller.window, let content = window.contentView else { continue }
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            model.stepDidAppear()
            for _ in 0..<40 { await Task.yield() }
            content.layoutSubtreeIfNeeded()
            write(content, variant.id)
            window.close()
        }
        let store = GalleryReviewStore(url: FileManager.default.temporaryDirectory.appending(path: "render-\(UUID().uuidString).json"))
        let gallery = OnboardingGalleryController(store: store, makeServices: { _ in self.sample() }, previewAppearance: { _ in })
        guard let window = gallery.window, let content = window.contentView else { return }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        for _ in 0..<40 { await Task.yield() }
        content.layoutSubtreeIfNeeded()
        write(content, "gallery")
        window.close()
    }
}
