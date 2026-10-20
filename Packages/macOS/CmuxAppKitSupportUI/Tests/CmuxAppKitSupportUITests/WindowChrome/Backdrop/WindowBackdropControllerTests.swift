import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct WindowBackdropControllerTests {
    @Test func opaqueWindowFillRemovesGlassAndResetsCompositorBlur() {
        let dependencies = FakeBackdropDependencies()
        dependencies.glass.removeResult = true
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()

        let result = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .opaqueWindowFill,
                windowBackgroundColor: .systemRed,
                windowIsOpaque: true,
                rootPolicy: .clear,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: false
            ),
            to: window
        )

        #expect(result.didChangeGlassRoot)
        #expect(!result.usesWindowGlass)
        #expect(dependencies.glass.removeCallCount == 1)
        #expect(dependencies.glass.applyCalls.isEmpty)
        #expect(dependencies.resetBlurWindowNumbers.count == 1)
        #expect(dependencies.appliedBlurWindows.isEmpty)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .systemRed)
    }

    @Test func transparentRootBackdropRemovesGlassAndAppliesGhosttyBlurWhenRequested() {
        let dependencies = FakeBackdropDependencies()
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()

        let result = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: .clear,
                windowIsOpaque: false,
                rootPolicy: .clear,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: true
            ),
            to: window
        )

        #expect(!result.usesWindowGlass)
        #expect(dependencies.glass.removeCallCount == 1)
        #expect(dependencies.resetBlurWindowNumbers.isEmpty)
        #expect(dependencies.appliedBlurWindows.first === window)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
    }

    @Test func windowGlassPlanAppliesInjectedGlassEffectAndResetsCompositorBlur() {
        let dependencies = FakeBackdropDependencies()
        dependencies.glass.applyResult = true
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()
        let tintColor = NSColor.systemBlue.withAlphaComponent(0.4)

        let result = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .windowGlass,
                windowBackgroundColor: .white.withAlphaComponent(0.001),
                windowIsOpaque: false,
                rootPolicy: .clear,
                glass: WindowBackdropGlassPlan(tintColor: tintColor, style: .clear),
                shouldApplyGhosttyCompositorBlur: false
            ),
            to: window
        )

        #expect(result.didChangeGlassRoot)
        #expect(result.usesWindowGlass)
        #expect(dependencies.glass.removeCallCount == 0)
        #expect(dependencies.glass.applyCalls.count == 1)
        #expect(dependencies.glass.applyCalls.first?.window === window)
        #expect(dependencies.glass.applyCalls.first?.tintColor == tintColor)
        #expect(dependencies.glass.applyCalls.first?.style == .clear)
        #expect(dependencies.resetBlurWindowNumbers.count == 1)
        #expect(dependencies.appliedBlurWindows.isEmpty)
        #expect(!window.isOpaque)
    }

    private func makeWindow() -> NSWindow {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }
}

@MainActor
private final class FakeBackdropDependencies: WindowBackdropControllerDependencies {
    let glass = FakeGlassEffect()
    var resetBlurWindowNumbers: [Int] = []
    var appliedBlurWindows: [NSWindow] = []

    var glassEffect: any WindowGlassEffectManaging {
        glass
    }

    func resetCompositorBackgroundBlur(windowNumber: Int) {
        resetBlurWindowNumbers.append(windowNumber)
    }

    func applyGhosttyCompositorBlurIfNeeded(to window: NSWindow) {
        appliedBlurWindows.append(window)
    }
}

@MainActor
private final class FakeGlassEffect: WindowGlassEffectManaging {
    struct ApplyCall {
        let window: NSWindow
        let tintColor: NSColor?
        let style: WindowGlassEffectStyle?
    }

    var backgroundViewIdentifier = NSUserInterfaceItemIdentifier("fake.background")
    var isAvailable = true
    var applyResult = false
    var removeResult = false
    var applyCalls: [ApplyCall] = []
    var updateTintCalls: [(window: NSWindow, color: NSColor?)] = []
    var removeCallCount = 0
    var foregroundContainerResult: NSView?
    var originalContentViewResult: NSView?
    var portalInstallationTargetResult: WindowContentOverlayInstallationTarget?

    func apply(
        to window: NSWindow,
        tintColor: NSColor?,
        style: WindowGlassEffectStyle?
    ) -> Bool {
        applyCalls.append(ApplyCall(window: window, tintColor: tintColor, style: style))
        return applyResult
    }

    func updateTint(to window: NSWindow, color: NSColor?) {
        updateTintCalls.append((window: window, color: color))
    }

    func remove(from window: NSWindow) -> Bool {
        removeCallCount += 1
        return removeResult
    }

    func foregroundContainer(for window: NSWindow) -> NSView? {
        foregroundContainerResult
    }

    func originalContentView(for window: NSWindow) -> NSView? {
        originalContentViewResult
    }

    func portalInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        portalInstallationTargetResult
    }
}
