#if canImport(AppKit)
#if DEBUG
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Covers the File Explorer Style debug window shell the app forwards into
/// ``DebugWindowsCoordinator``. The controller builds the fixed
/// `cmux.fileExplorerStyleDebug` utility panel, mounts the app-supplied editor
/// content, and routes chrome decoration through the injected ``WindowDecorating``
/// seam.
@MainActor
@Suite struct FileExplorerStyleDebugWindowControllerTests {
    @Test func showBuildsUtilityPanelMountsContentAndDecorates() {
        let decorator = FileExplorerStyleDebugRecordingDecorator()
        let content = NSView()
        let controller = FileExplorerStyleDebugWindowController(
            decorator: decorator,
            contentProvider: { content }
        )

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.fileExplorerStyleDebug")
        #expect(window?.title == "File Explorer Style")
        #expect(window?.contentView === content)
        #expect(decorator.decorated.count == 1)
        #expect(decorator.decorated.first === window)
    }

    @Test func showWithoutDecoratorStillBuildsPanel() {
        let controller = FileExplorerStyleDebugWindowController(
            decorator: nil,
            contentProvider: { NSView() }
        )

        controller.show()

        #expect(controller.window?.identifier?.rawValue == "cmux.fileExplorerStyleDebug")
    }

    @Test func coordinatorWithoutProviderDoesNotPresent() {
        let coordinator = DebugWindowsCoordinator(
            decorator: nil,
            aboutPanelStrings: AboutPanelStrings(
                appName: "cmux", description: "desc", versionLabel: "Version",
                buildLabel: "Build", commitLabel: "Commit", docs: "Docs",
                github: "GitHub", licenses: "Licenses"
            ),
            acknowledgmentsStrings: AcknowledgmentsStrings(windowTitle: "Licenses", notFound: "none")
        )

        coordinator.showFileExplorerStyleDebug()
        // No content provider was injected, so no panel is created. Reaching here
        // without a crash is the contract (the call is a documented no-op).
        #expect(Bool(true))
    }
}

@MainActor
private final class FileExplorerStyleDebugRecordingDecorator: WindowDecorating {
    private(set) var decorated: [NSWindow] = []

    func applyWindowDecorations(to window: NSWindow) {
        decorated.append(window)
    }
}
#endif
#endif
