import AppKit
import CmuxNextActions
import CmuxNextApps
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextSettingsWindow
import Testing

/// Lane 20: every window of its own shows the standard close button:
/// closable, the button present, shown, opaque, inside the frame, and in a
/// titlebar above the content view (a full-size content view must not
/// cover it).
@MainActor
@Suite(.serialized)
struct SecondaryWindowCloseButtonTests {
    static func expectCloseButton(_ window: NSWindow?, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let window, let content = window.contentView, let frameView = content.superview else {
            Issue.record("\(label): no window", sourceLocation: sourceLocation)
            return
        }
        #expect(window.styleMask.contains(.closable), "\(label) is not closable", sourceLocation: sourceLocation)
        window.layoutIfNeeded()
        guard let button = window.standardWindowButton(.closeButton) else {
            Issue.record("\(label): no close button", sourceLocation: sourceLocation)
            return
        }
        #expect(!button.isHiddenOrHasHiddenAncestor, "\(label): close button hidden", sourceLocation: sourceLocation)
        #expect(button.alphaValue == 1, "\(label): close button alpha \(button.alphaValue)", sourceLocation: sourceLocation)
        let rect = button.convert(button.bounds, to: frameView)
        #expect(rect.width > 0 && frameView.bounds.contains(rect), "\(label): close button at \(rect)", sourceLocation: sourceLocation)
        var holder: NSView = button
        while let parent = holder.superview, parent !== frameView { holder = parent }
        let order = frameView.subviews
        let holderIndex = order.firstIndex { $0 === holder } ?? -1
        let contentIndex = order.firstIndex { $0 === content } ?? Int.max
        #expect(holderIndex > contentIndex, "\(label): close button under the content view", sourceLocation: sourceLocation)
    }

    @Test func settingsAndDebugSettingsWindowsHaveACloseButton() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let registry = ActionRegistry(catalog: [])
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        await settings.reload()
        let settingsWindow = SettingsWindowController(model: SettingsWindowModel(settings: settings, registry: registry, host: nil))
        Self.expectCloseButton(settingsWindow.window, "Settings")
        let debug = DebugSettingsWindowController(model: DebugSettingsModel(store: TunableStore(), descriptors: []))
        Self.expectCloseButton(debug.window, "Debug Settings")
    }

    @Test func onboardingWindowHasACloseButton() {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.firstTaskView = NSView()
        let controller = OnboardingWindowController(model: OnboardingModel(services: services, start: .role))
        Self.expectCloseButton(controller.window, "Onboarding")
    }

    /// The App Store window (fallback when no main window holds the tab).
    @Test func appStoreWindowHasACloseButton() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-store-close-\(UUID().uuidString)")
        let registry = AppRegistry(directory: root, firstPartyRoot: root.appending(path: "none"))
        let model = AppStoreModel(catalog: RegistryAppStoreCatalog(registry: registry), registry: registry,
                                  host: AppHost(sink: AppPreviewSink()), previewHost: AppHost(sink: AppPreviewSink()))
        let controller = AppStoreWindowController(model: model)
        Self.expectCloseButton(controller.window, "App Store")
    }
}
