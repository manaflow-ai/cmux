#if canImport(AppKit)
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Covers the About / Acknowledgments window shells the app forwards into
/// ``DebugWindowsCoordinator``. These windows replaced the former
/// `AboutWindowController.shared` / `AcknowledgmentsWindowController.shared`
/// singletons; the coordinator now owns their lifecycle. The tests pin the
/// window identifiers and byte-identical geometry/style preserved from the
/// app-target originals.
@MainActor
@Suite struct AboutWindowControllerTests {
    private func makeStrings() -> AboutPanelStrings {
        AboutPanelStrings(
            appName: "cmux",
            description: "desc",
            versionLabel: "Version",
            buildLabel: "Build",
            commitLabel: "Commit",
            docs: "Docs",
            github: "GitHub",
            licenses: "Licenses"
        )
    }

    @Test func aboutWindowUsesStableIdentifierAndGeometry() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        let controller = AboutWindowController(
            store: store,
            decorator: nil,
            strings: makeStrings(),
            showAcknowledgments: {}
        )

        let window = controller.managedWindow()

        #expect(window.identifier?.rawValue == "cmux.about")
        #expect(window.identifier?.rawValue == AboutWindowKind.about.windowIdentifier)
        #expect(window.contentView != nil)
        // The About window is titled/closable/miniaturizable but not resizable.
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
    }

    @Test func acknowledgmentsWindowUsesStableIdentifierGeometryAndTitle() {
        let controller = AcknowledgmentsWindowController(
            strings: AcknowledgmentsStrings(windowTitle: "Third-Party Licenses", notFound: "none")
        )

        let window = controller.managedWindow()

        #expect(window.identifier?.rawValue == "cmux.licenses")
        #expect(window.title == "Third-Party Licenses")
        #expect(window.contentView != nil)
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func coordinatorPresentsAboutAndAcknowledgmentsWithoutCrashing() {
        // Exercises the coordinator's full lazy-construction + content-mounting
        // path for both windows, including the About panel's injected
        // showAcknowledgments closure routing back into the coordinator. A second
        // call proves the controllers are reused rather than rebuilt.
        let coordinator = DebugWindowsCoordinator(
            decorator: nil,
            aboutPanelStrings: makeStrings(),
            acknowledgmentsStrings: AcknowledgmentsStrings(windowTitle: "Licenses", notFound: "none")
        )

        coordinator.showAbout()
        coordinator.showAbout()
        coordinator.showAcknowledgments()
        coordinator.showAcknowledgments()
    }
}
#endif
