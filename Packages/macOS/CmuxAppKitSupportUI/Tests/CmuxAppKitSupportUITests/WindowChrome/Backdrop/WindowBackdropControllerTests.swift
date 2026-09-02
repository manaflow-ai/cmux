import AppKit
import QuartzCore
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct WindowBackdropControllerTests {
    @Test func opaqueRootBackdropUsesOrdinaryLayerBelowWindowContent() throws {
        let dependencies = FakeBackdropDependencies()
        dependencies.glass.removeResult = true
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()

        let result = controller.apply(plan: makeOpaqueRootPlan(color: .systemRed), to: window)

        #expect(result.didChangeGlassRoot)
        #expect(!result.usesWindowGlass)
        #expect(dependencies.glass.removeCallCount == 1)
        #expect(dependencies.glass.applyCalls.isEmpty)
        #expect(dependencies.resetBlurWindowNumbers.count == 1)
        #expect(dependencies.appliedBlurWindows.isEmpty)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .clear)

        let contentView = try #require(window.contentView)
        let themeFrame = try #require(contentView.superview)
        let rootBackdrop = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let rootIndex = try #require(themeFrame.subviews.firstIndex { $0 === rootBackdrop })
        let contentIndex = try #require(themeFrame.subviews.firstIndex { $0 === contentView })
        #expect(rootIndex < contentIndex)
        #expect(rootBackdrop.layer?.backgroundColor == NSColor.systemRed.cgColor)
        #expect(rootBackdrop.layer?.isOpaque == true)
        #expect(!rootBackdrop.layerUsesCoreImageFilters)
        #expect(rootBackdrop.compositingFilter == nil)

        _ = controller.apply(plan: makeOpaqueRootPlan(color: .systemBlue), to: window)
        let updatedRoot = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        #expect(updatedRoot === rootBackdrop)
        #expect(updatedRoot.layer?.backgroundColor == NSColor.systemBlue.cgColor)

        _ = controller.apply(
            plan: makeOpaqueRootPlan(color: .systemGreen, opacity: 0.999),
            to: window
        )
        let compositedColor = try #require(
            updatedRoot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        #expect(abs(compositedColor.alphaComponent - 1) < 0.0001)
        #expect(updatedRoot.layer?.isOpaque == true)
    }

    @Test func transparentRootBackdropReusesRootAndPreservesFractionalAlpha() throws {
        let dependencies = FakeBackdropDependencies()
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()
        _ = controller.apply(plan: makeOpaqueRootPlan(color: .systemRed), to: window)
        let installedRoot = try #require(
            window.contentView?.superview?.subviews.first { $0 is WindowRootBackdropView }
                as? WindowRootBackdropView
        )
        dependencies.glass.removeCallCount = 0
        dependencies.resetBlurWindowNumbers.removeAll()

        let result = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: .clear,
                windowIsOpaque: false,
                rootPolicy: .ghosttyTerminalBackdrop(
                    color: .systemPurple,
                    opacity: 0.42,
                    renderingMode: .windowHostBackdrop
                ),
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
        let contentView = try #require(window.contentView)
        let themeFrame = try #require(contentView.superview)
        let transparentRoot = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let color = try #require(
            transparentRoot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        #expect(transparentRoot === installedRoot)
        #expect(abs(color.alphaComponent - 0.42) < 0.0001)
        #expect(transparentRoot.layer?.isOpaque == false)
        #expect(!transparentRoot.layerUsesCoreImageFilters)
        #expect(transparentRoot.compositingFilter == nil)
    }

    @Test func rootBackdropReassertsAdjacencyAfterFallbackGlassInsertion() throws {
        let dependencies = FakeBackdropDependencies()
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()
        _ = controller.apply(plan: makeOpaqueRootPlan(color: .systemRed), to: window)

        let contentView = try #require(window.contentView)
        let themeFrame = try #require(contentView.superview)
        let rootBackdrop = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let fallbackGlass = NSVisualEffectView(frame: themeFrame.bounds)
        themeFrame.addSubview(fallbackGlass, positioned: .below, relativeTo: contentView)

        let initialRootIndex = try #require(themeFrame.subviews.firstIndex { $0 === rootBackdrop })
        let initialContentIndex = try #require(themeFrame.subviews.firstIndex { $0 === contentView })
        #expect(initialRootIndex < initialContentIndex - 1)

        controller.updateRootBackdropExclusions([], in: window)

        let repairedRootIndex = try #require(themeFrame.subviews.firstIndex { $0 === rootBackdrop })
        let repairedContentIndex = try #require(themeFrame.subviews.firstIndex { $0 === contentView })
        #expect(repairedRootIndex == repairedContentIndex - 1)
        #expect(themeFrame.subviews[repairedRootIndex + 1] === contentView)
    }

    @Test func windowGlassPlanMovesSameRootBelowGlassForegroundContent() throws {
        let dependencies = FakeBackdropDependencies()
        dependencies.glass.applyResult = true
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow()
        _ = controller.apply(plan: makeOpaqueRootPlan(color: .systemRed), to: window)
        let installedRoot = try #require(
            window.contentView?.superview?.subviews.first { $0 is WindowRootBackdropView }
                as? WindowRootBackdropView
        )
        dependencies.glass.removeCallCount = 0
        dependencies.resetBlurWindowNumbers.removeAll()
        let tintColor = NSColor.systemBlue.withAlphaComponent(0.4)
        let glassContainer = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let glassReference = NSView(frame: glassContainer.bounds)
        glassContainer.addSubview(glassReference)
        let themeFrame = try #require(window.contentView?.superview)
        themeFrame.addSubview(glassContainer)
        dependencies.glass.portalInstallationTargetResult = WindowContentOverlayInstallationTarget(
            container: glassContainer,
            reference: glassReference
        )

        let result = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .windowGlass,
                windowBackgroundColor: .white.withAlphaComponent(0.001),
                windowIsOpaque: false,
                rootPolicy: .ghosttyTerminalBackdrop(
                    color: .systemPurple,
                    opacity: 0.35,
                    renderingMode: .windowHostBackdrop
                ),
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
        let glassRoot = try #require(
            glassContainer.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let rootIndex = try #require(glassContainer.subviews.firstIndex { $0 === glassRoot })
        let referenceIndex = try #require(glassContainer.subviews.firstIndex { $0 === glassReference })
        let color = try #require(glassRoot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(glassRoot === installedRoot)
        #expect(rootIndex < referenceIndex)
        #expect(abs(color.alphaComponent - 0.35) < 0.0001)

        dependencies.glass.portalInstallationTargetResult = nil
        _ = controller.apply(plan: makeOpaqueRootPlan(color: .systemGreen), to: window)
        let restoredRoot = try #require(
            window.contentView?.superview?.subviews.first { $0 is WindowRootBackdropView }
                as? WindowRootBackdropView
        )
        #expect(restoredRoot === installedRoot)
    }

    @Test func rootMaskUsesExactUnionForOverlappingPaneExclusions() throws {
        let dependencies = FakeBackdropDependencies()
        let controller = WindowBackdropController(dependencies: dependencies)
        let window = makeWindow(styleMask: [.borderless])
        _ = controller.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: .clear,
                windowIsOpaque: false,
                rootPolicy: .ghosttyTerminalBackdrop(
                    color: .systemPurple,
                    opacity: 0.42,
                    renderingMode: .windowHostBackdrop
                ),
                glass: nil,
                shouldApplyGhosttyCompositorBlur: false
            ),
            to: window
        )

        let contentView = try #require(window.contentView)
        let themeFrame = try #require(contentView.superview)
        themeFrame.layoutSubtreeIfNeeded()
        let root = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        root.layoutSubtreeIfNeeded()
        let first = NSRect(x: 20, y: 15, width: 50, height: 40)
        let second = NSRect(x: 45, y: 30, width: 50, height: 35)
        controller.updateRootBackdropExclusions(
            [root.convert(first, to: nil), root.convert(second, to: nil)],
            in: window
        )

        let mask = try #require(root.layer?.mask as? CAShapeLayer)
        let path = try #require(mask.path)
        #expect(mask.fillRule == .evenOdd)
        #expect(path.contains(NSPoint(x: 5, y: 5), using: .evenOdd))
        #expect(!path.contains(NSPoint(x: 25, y: 20), using: .evenOdd))
        #expect(!path.contains(NSPoint(x: 50, y: 40), using: .evenOdd))
        #expect(!path.contains(NSPoint(x: 90, y: 60), using: .evenOdd))
    }

    private func makeWindow(
        styleMask: NSWindow.StyleMask = [.titled, .closable]
    ) -> NSWindow {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }

    private func makeOpaqueRootPlan(
        color: NSColor,
        opacity: CGFloat = 1
    ) -> WindowBackdropPlan {
        WindowBackdropPlan(
            hostingPhase: .opaqueRootBackdrop,
            windowBackgroundColor: .clear,
            windowIsOpaque: true,
            rootPolicy: .ghosttyTerminalBackdrop(
                color: color,
                opacity: opacity,
                renderingMode: .windowHostBackdrop
            ),
            glass: nil,
            shouldApplyGhosttyCompositorBlur: false
        )
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
