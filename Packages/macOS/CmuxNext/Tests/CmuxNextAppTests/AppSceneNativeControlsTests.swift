import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Every node a custom section (or an app pane) can use draws in AppKit, so no custom view falls back
/// to SwiftUI and looks unlike the sidebar: Toggle, TextField, Slider, Image, Menu, ProgressView,
/// ZStack and the shapes, and the decoration props (`frame`, `background`, `borderColor`,
/// `cornerRadius`, `hoverBackground`, `rotation`). Each control sends its events back to the script.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneNativeControlsTests {
    private final class Recorder: AppSceneInteraction {
        var events: [(node: String, event: String, payload: AppJSON)] = []
        func dispatch(node: String, event: String, payload: AppJSON) { events.append((node, event, payload)) }
    }

    private static func scene(_ ops: [AppSceneOp]) -> AppSceneModel {
        let model = AppSceneModel()
        model.apply(ops)
        return model
    }

    private static func host(_ model: AppSceneModel, bundle: URL? = nil, width: CGFloat = 260) -> (NSWindow, AppSceneHostingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = AppSceneHostingView(model: model, bundleDirectory: bundle)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func all(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all(in: $0) } }
    private static func first<T: NSView>(_ type: T.Type, in root: NSView) -> T? { all(in: root).lazy.compactMap { $0 as? T }.first }
    private static func hasSwiftUIHost(_ root: NSView) -> Bool {
        all(in: root).contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") }
    }

    /// A scene with one of each control the SwiftUI renderer used to draw alone.
    private static func controls() -> AppSceneModel {
        scene([
            .create(id: "list", type: "VStack", props: ["spacing": 4]),
            .create(id: "toggle", type: "Toggle", props: ["label": "Show drafts", "value": false, "onChange": true]),
            .create(id: "field", type: "TextField", props: ["placeholder": "Filter", "text": "", "onEdit": true]),
            .create(id: "slider", type: "Slider", props: ["min": 0, "max": 10, "step": 1, "value": 3, "onChange": true]),
            .create(id: "menu", type: "Menu", props: ["title": "Sort", "menu": [["title": "Newest"], ["title": "Oldest"]]]),
            .create(id: "progress", type: "ProgressView", props: ["value": 0.5]),
            .create(id: "spinner", type: "ProgressView", props: [:]),
            .create(id: "z", type: "ZStack", props: [:]),
            .create(id: "dot", type: "Circle", props: ["size": 8, "fill": "success"]),
            .create(id: "box", type: "RoundedRectangle", props: ["size": 12, "stroke": "secondary"]),
            .children(id: "z", children: ["dot", "box"]),
            .children(id: "list", children: ["toggle", "field", "slider", "menu", "progress", "spinner", "z"]),
            .root(id: "list"),
        ])
    }

    @Test func everyControlDrawsInAppKit() {
        let (window, root) = Self.host(Self.controls())
        defer { window.contentView = nil; window.close() }
        #expect(!Self.hasSwiftUIHost(root), "no node falls back to an NSHostingView")
        #expect(Self.first(NSSwitch.self, in: root) != nil)
        #expect(Self.first(ThemedTextField.self, in: root)?.placeholderString == "Filter")
        #expect(Self.first(NSSlider.self, in: root)?.doubleValue == 3)
        #expect(Self.all(in: root).contains { $0.accessibilityRole() == .progressIndicator && ($0.accessibilityValue() as? Double) == 0.5 })
        #expect(Self.first(StatusIndicatorView.self, in: root) != nil, "an indeterminate ProgressView is the themed spinner")
        #expect(Self.all(in: root).contains { $0.accessibilityRole() == .menuButton && $0.accessibilityLabel() == "Sort" })
        #expect(root.preferredHeight(width: 260) > 0)
    }

    @Test func toggleSendsChangeWithItsNewValue() throws {
        let model = Self.controls()
        let recorder = Recorder()
        model.interaction = recorder
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let control = try #require(Self.first(NSSwitch.self, in: root))
        #expect(control.state == .off)
        control.performClick(nil)
        #expect(recorder.events.map(\.event) == ["change"])
        #expect(recorder.events.first?.payload["value"]?.boolValue == true)
        // The app's echo keeps it on; the app's next value wins.
        model.apply([.update(id: "toggle", props: ["label": "Show drafts", "value": true, "onChange": true])])
        root.layoutSubtreeIfNeeded()
        #expect(control.state == .on)
        model.apply([.update(id: "toggle", props: ["label": "Show drafts", "value": false, "onChange": true])])
        root.layoutSubtreeIfNeeded()
        #expect(control.state == .off)
    }

    @Test func textFieldSendsEditAndSubmit() throws {
        let model = Self.controls()
        let recorder = Recorder()
        model.interaction = recorder
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let field = try #require(Self.first(ThemedTextField.self, in: root))
        field.stringValue = "fix"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.sendAction(field.action, to: field.target)
        #expect(recorder.events.map(\.event) == ["edit", "submit"])
        #expect(recorder.events.map { $0.payload["text"]?.stringValue } == ["fix", "fix"])
    }

    @Test func sliderSendsSnappedChange() throws {
        let model = Self.controls()
        let recorder = Recorder()
        model.interaction = recorder
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let slider = try #require(Self.first(NSSlider.self, in: root))
        slider.doubleValue = 6.4
        slider.sendAction(slider.action, to: slider.target)
        #expect(recorder.events.map(\.event) == ["change"])
        #expect(recorder.events.first?.payload["value"]?.numberValue == 6)
    }

    @Test func menuPickSendsItsPath() throws {
        let model = Self.controls()
        let recorder = Recorder()
        model.interaction = recorder
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let button = try #require(Self.all(in: root).first { $0.accessibilityRole() == .menuButton })
        let menu = try #require(button.menu, "the menu button's pull-down is its menu")
        #expect(menu.items.map(\.title) == ["Newest", "Oldest"])
        menu.performActionForItem(at: 1)
        #expect(recorder.events.map(\.event) == ["menu"])
        #expect(recorder.events.first?.payload["path"] == .array([.number(1)]))
    }

    @Test func imageDrawsTheBundleFile() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "scene-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundle.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(pixel?.representation(using: .png, properties: [:])).write(to: bundle.appending(path: "assets/logo.png"))
        let model = Self.scene([
            .create(id: "image", type: "Image", props: ["src": "assets/logo.png", "frame": ["width": 40]]),
            .root(id: "image"),
        ])
        let (window, root) = Self.host(model, bundle: bundle)
        defer { window.contentView = nil; window.close() }
        #expect(!Self.hasSwiftUIHost(root))
        let image = try #require(Self.first(NSImageView.self, in: root))
        #expect(image.image != nil)
        #expect(root.preferredHeight(width: 260) == 20, "scaled to fit its 40 pt frame: half as high as wide")
    }

    @Test func decorationPropsSizeAndPaintTheNode() throws {
        let model = Self.scene([
            .create(id: "list", type: "VStack", props: [:]),
            .create(id: "chip", type: "Text", props: ["text": "Draft", "frame": ["height": 30, "width": 80], "background": "accent",
                                                       "borderColor": "separator", "cornerRadius": 6, "hoverBackground": "secondary",
                                                       "rotation": 0]),
            .children(id: "list", children: ["chip"]),
            .root(id: "list"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        #expect(!Self.hasSwiftUIHost(root))
        #expect(root.preferredHeight(width: 260) == 30)
        let chip = try #require(Self.all(in: root).compactMap { $0 as? AppSceneNodeNSView }.first { $0.nodeID == "chip" })
        #expect(chip.frame.size == NSSize(width: 80, height: 30))
        let layer = try #require(chip.layer)
        #expect(layer.backgroundColor != nil)
        #expect(layer.borderWidth == 1)
        #expect(layer.cornerRadius == 6)
    }

    /// The GitHub PRs sample's section (samples/apps/github-prs/src/main.ts): rows with help, tap and a
    /// context menu, then the empty state, all native.
    @Test func theGitHubPRsSampleDrawsNatively() throws {
        let model = Self.scene([
            .create(id: "list", type: "VStack", props: ["spacing": 2]),
            .create(id: "each", type: "ForEach", props: [:]),
            .create(id: "pr", type: "Row", props: ["title": "Native controls", "subtitle": "manaflow-ai/cmux #38200 · Merged",
                                                    "symbol": "checkmark.circle", "tint": "accent", "help": "https://github.com",
                                                    "onTap": true,
                                                    "menu": [["title": "Open in Browser"], ["divider": true], ["title": "Refresh"]]]),
            .create(id: "empty", type: "EmptyState", props: ["title": "No pull requests in the last 24 hours", "symbol": "clock"]),
            .children(id: "each", children: ["pr"]),
            .children(id: "list", children: ["each", "empty"]),
            .root(id: "list"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        #expect(!Self.hasSwiftUIHost(root))
        #expect(Self.all(in: root).contains { $0.isAccessibilityElement() && $0.accessibilityLabel() == "Native controls" })
    }
}
