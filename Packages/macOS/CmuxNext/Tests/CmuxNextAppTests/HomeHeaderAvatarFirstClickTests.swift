import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import MessagesLabHome
import Testing

/// cx-3x9t (nxdog72 preflight): a click on the Home transcript header's
/// avatar did nothing in the real app, while the "Chief >" name pill opened
/// the Chief's settings. The click reaches the window, which is not key (an
/// inactive app, a background window, an agent launch with no activation),
/// and `NSWindow.sendEvent` passes a first click on to a view only when the
/// view accepts the first mouse: the pill (an `NSButton`) does, the header
/// view under the avatar did not, so the window took the click and
/// `PaneHeaderView.mouseDown` never ran. The test drives the real window
/// (`ShellWindow` from `WindowController`, the Home top page, the shown
/// conversation's header) through `sendEvent`, as `debug.mouse` and the
/// window server do.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HomeHeaderAvatarFirstClickTests {
    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    @Test(.requiresGUISession) func aFirstClickOnTheAvatarInAWindowThatIsNotKeyOpensTheContact() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try TopPageTests.homeTree())
        let home = try #require(services.daemon.store.workspaces.first { $0.kind == "home" })
        let state = WindowState(workspaceID: home.id)
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        services.windows.didActivate(controller)
        await BrowserTabTests.settle { controller.shownTopPage != nil }
        defer {
            controller.teardown()
            withExtendedLifetime((services, state)) {}
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let page = try #require(Self.find(TopHomePageView.self, in: root), "the Home top page")
        page.show(ConversationID("conv_avatar_first_click"))
        root.layoutSubtreeIfNeeded()
        let header = try #require(Self.find(PaneHeaderView.self, in: root), "the transcript header")
        header.title = "Chief"
        header.initials = "C"
        root.layoutSubtreeIfNeeded()
        var contacts = 0
        let open = header.onContact
        header.onContact = {
            contacts += 1
            open()
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(!window.isKeyWindow, "the window must not be key: the bug is the first click")

        let avatar = header.avatar.convert(header.avatar.bounds, to: nil)
        let point = NSPoint(x: avatar.midX, y: avatar.midY)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        #expect(contacts == 1, "a first click on the avatar does not open the contact (the window swallowed it)")
    }
}
