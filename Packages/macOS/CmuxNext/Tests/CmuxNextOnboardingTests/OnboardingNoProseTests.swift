import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Leo, 2026-10-06: labels and actions only. The default Accounts and
/// Import screens (the ones a Release first run shows) say nothing about
/// where data goes or what a profile becomes.
@MainActor
@Suite(.serialized) struct OnboardingNoProseTests {
    static let prose = ["Sign-ins cmux found", "Nothing is uploaded", "Nothing leaves this Mac", "Each profile becomes",
                         "macOS asks before"]

    static func shownText(_ view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor { found.append(field.stringValue) }
        for child in view.subviews { found += shownText(child) }
        return found
    }

    @Test(arguments: [OnboardingModel.Step.accounts, .importData])
    func theDefaultScreenHasNoProse(_ step: OnboardingModel.Step) async {
        let services = MockOnboardingServices.gallerySample(themes: [], accountsView: NSView())
        let model = OnboardingModel(services: services, start: step)
        let controller = OnboardingWindowController(model: model, variant: step.variants[0])
        guard let window = controller.window, let content = window.contentView else {
            Issue.record("no window for \(step)")
            return
        }
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        model.stepDidAppear()
        for _ in 0..<30 { await Task.yield() }
        content.layoutSubtreeIfNeeded()
        let text = Self.shownText(content)
        let offending = text.filter { line in Self.prose.contains { line.contains($0) } }
        #expect(offending.isEmpty, "\(step): \(offending)")
    }
}
