import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// The kit a vibe-coded app pane matches the app with: `Toggle`, `Slider` and `Panel` scene nodes,
/// drawn with the app's own controls and surfaces in the scope's theme.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneKitTests {
    private final class Recorder: AppSceneInteraction {
        var events: [(node: String, event: String, payload: AppJSON)] = []
        func dispatch(node: String, event: String, payload: AppJSON) { events.append((node, event, payload)) }
    }

    private static func host(_ model: AppSceneModel, _ id: String, size: NSSize = NSSize(width: 260, height: 120)) throws -> (NSWindow, NSView) {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The sidebar's own AppKit host of a scene, at the given size (the scene draws its root).
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        scope.root(hosting)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    @Test func theKitsNodeTypesAreDrawnNotDropped() {
        let model = AppSceneModel()
        model.apply([
            .create(id: "p", type: "Panel", props: ["title": "Timer", "style": "glass"]),
            .create(id: "t", type: "Toggle", props: ["value": true, "label": "Sounds", "onChange": true]),
            .create(id: "s", type: "Slider", props: ["value": 25, "min": 5, "max": 60, "step": 5, "onChange": true]),
            .children(id: "p", children: ["t", "s"]),
            .root(id: "p"),
        ])
        #expect(model.scene["p"]?.type == .panel)
        #expect(model.scene["t"]?.type == .toggle)
        #expect(model.scene["s"]?.type == .slider)
        #expect(model.status == .ready)
    }

    @Test func aToggleIsANativeSwitchThatSendsItsNewValue() throws {
        let model = AppSceneModel()
        let recorder = Recorder()
        model.interaction = recorder
        model.apply([.create(id: "t", type: "Toggle", props: ["value": false, "label": "Sounds", "onChange": true]), .root(id: "t")])
        let (window, root) = try Self.host(model, "t")
        defer { window.contentView = nil; window.close() }
        let control = try #require(Self.all(NSSwitch.self, in: root).first, "the native switch")
        #expect(control.state == .off)
        control.performClick(nil)
        root.layoutSubtreeIfNeeded()
        #expect(recorder.events.map(\.event) == ["change"])
        #expect(recorder.events.first?.payload["value"]?.boolValue == true)
    }

    @Test func aToggleWithNoOnChangeShowsTheAppsValueAndDoesNotFlip() throws {
        let model = AppSceneModel()
        let recorder = Recorder()
        model.interaction = recorder
        model.apply([.create(id: "t", type: "Toggle", props: ["value": true, "label": "Sounds"]), .root(id: "t")])
        let (window, root) = try Self.host(model, "t")
        defer { window.contentView = nil; window.close() }
        let control = try #require(Self.all(NSSwitch.self, in: root).first, "the native switch")
        #expect(control.state == .on)
        #expect(!control.isEnabled, "a display-only switch is disabled")
        control.performClick(nil)
        root.layoutSubtreeIfNeeded()
        #expect(control.state == .on, "a display-only switch keeps the app's value")
        #expect(recorder.events.isEmpty)
    }

    @Test func aSliderSnapsToItsStepWithinItsRange() {
        let node = AppSceneNode(type: .slider, props: ["min": 5, "max": 60, "step": 5])
        let range = AppSceneSlider.range(node)
        let step = AppSceneSlider.step(node, range)
        #expect(range == 5...60)
        #expect(AppSceneSlider.snap(27.4, range, step) == 25)
        #expect(AppSceneSlider.snap(28, range, step) == 30)
        #expect(AppSceneSlider.snap(99, range, step) == 60)
        #expect(AppSceneSlider.snap(-3, range, step) == 5)
        // A decimal step sends the step's own value, not its float drift.
        #expect(AppSceneSlider.snap(0.30000001, 0...1, 0.1) == 0.3)
        #expect(AppSceneSlider.snap(0.7, 0...1, 0.05) == 0.7)
        // The rounding never leaves the range: a min finer than the step's decimals stays reachable.
        #expect(AppSceneSlider.snap(0, 0.123456789...1, 0.1) >= 0.123456789)
        // No step: a hundredth of the range. A reversed range is the default 0...1.
        let plain = AppSceneNode(type: .slider, props: ["min": 1, "max": 0])
        #expect(AppSceneSlider.range(plain) == 0...1)
        #expect(AppSceneSlider.step(plain, 0...1) == 0.01)
    }

    /// On macOS 26 SwiftUI backs a Slider with an NSSlider, which this reads; macOS 27 draws it
    /// without one, so there the test only checks the scene hosted (the snapping is tested above).
    @Test func aSliderIsANativeSliderAtItsValue() throws {
        let model = AppSceneModel()
        model.apply([.create(id: "s", type: "Slider", props: ["value": 25, "min": 5, "max": 60, "step": 5, "onChange": true]), .root(id: "s")])
        let (window, root) = try Self.host(model, "s")
        defer { window.contentView = nil; window.close() }
        guard let slider = Self.all(NSSlider.self, in: root).first else {
            #expect(model.status == .ready)
            return
        }
        // SwiftUI may drive the NSSlider over a normalized range: compare the thumb's fraction, 25 in 5...60.
        let fraction = (slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue)
        #expect(abs(fraction - 20.0 / 55.0) < 0.001)
    }

    @Test func aGlassPanelIsTheSidebarCardsSurfaceAndACardIsNot() throws {
        for (style, glass) in [("glass", true), ("card", false)] {
            let model = AppSceneModel()
            model.apply([
                .create(id: "p", type: "Panel", props: ["title": "Timer", "style": .string(style)]),
                .create(id: "x", type: "Text", props: ["text": "25:00"]),
                .children(id: "p", children: ["x"]),
                .root(id: "p"),
            ])
            let (window, root) = try Self.host(model, "p")
            defer { window.contentView = nil; window.close() }
            let surfaces = Self.all(CardSurfaceView.self, in: root)
            #expect(surfaces.isEmpty == !glass, "\(style)")
            if let surface = surfaces.first {
                #expect(surface.takesThemeTint, "the glass takes the theme's cast")
                #expect(surface.cornerRadius == Metrics.space3)
            }
        }
    }
}
