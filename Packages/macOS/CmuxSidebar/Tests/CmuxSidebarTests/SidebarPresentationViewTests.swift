import AppKit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import Testing
@testable import CmuxSidebar

@MainActor
@Suite
struct SidebarPresentationViewTests {
    @Test
    func nativeButtonRoutesItsTypedActionIdentifier() throws {
        _ = NSApplication.shared
        var receivedActionIDs: [String] = []
        let presentationView = CMUXSidebarPresentationView()

        presentationView.update(
            presentation: CmuxSidebarPresentation(
                root: .button(CmuxSidebarPresentationButton(
                    id: "workspace:example",
                    title: "Example",
                    systemImageName: "terminal"
                ))
            ),
            onAction: { receivedActionIDs.append($0) }
        )

        let button = try #require(findButton(in: presentationView))
        #expect(button.accessibilityIdentifier() == "CMUXExtensionAction.workspace:example")
        button.performClick(nil)
        #expect(receivedActionIDs == ["workspace:example"])
    }

    private func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap(findButton).first
    }
}
