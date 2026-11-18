import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane

/// SPLIT NEW PANE GROUND (m81, cmux-ad, Lawrence: during a split "the gap shows the page colour ... no blank or
/// stale-colour frames"). A split's new chat pane (Cmd-D, Cmd-Shift-D: a New Tab page, or a chat) showed the WINDOW
/// colour for 4 to 10 frames (cmux21, 120 Hz, both engines): its page had not drawn there yet (an adopted spare held
/// away or clear until its next frame, a new page under its loading cover) and nothing in the pane painted the page's
/// ground under it. From the turn the pane is made, the chat's own ground (what its page paints under its content,
/// `appearance.surfaces`) shows where the page will draw, before the page's first paint, in either engine. The row the
/// chat shares with its pane's tabs stays clear (Leo 2026-11-03: no backing behind the tabs).
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentPaneNewPaneGroundTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let chromium: Bool
        let newTab: Bool
        var testDescription: String { "\(chromium ? "Chromium" : "WebKit") \(newTab ? "New Tab page" : "chat")" }
    }

    nonisolated static let cases = [false, true].flatMap { chromium in [true, false].map { Case(chromium: chromium, newTab: $0) } }

    /// The window colour the pane's area shows where nothing paints over it (the kit's FF00FF).
    static let window = ThemeRGB(hex: 0xFF00FF)
    /// The chat's own ground (`appearance.surfaces`; the kit's 0000FF).
    static let chatGround = ThemeRGB(hex: 0x0000FF)

    /// The pixel at `point` (the host's coordinates, origin bottom left) of `host`'s layer tree as it would draw now.
    static func pixel(of host: NSView, at point: CGPoint) throws -> [Int] {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let (width, height) = (Int(host.bounds.width), Int(host.bounds.height))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try #require(host.layer).render(in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // A bitmap context's first row is the image's top.
        let offset = ((height - 1 - Int(point.y)) * width + Int(point.x)) * 4
        return (0..<3).map { Int(data[offset + $0]) }
    }

    static func rgb(_ color: ThemeRGB) -> [Int] {
        [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    /// A new pane's chat in a pane area that shows the window colour, its page not drawn yet, under a scope whose
    /// `appearance.surfaces` give `surface` the background `ground`.
    /// The scope is the caller's to keep: the registry holds it weakly.
    func pane(_ c: Case, ground: SurfaceBackground) async throws -> (AgentPaneView, NSView, NSWindow, ThemeScope) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: c.newTab ? AgentPaneNewTab(kind: .agent) : nil),
                                              source: .bundled(file), pageHost: c.chromium, testRoot: true,
                                              chromium: FakeChromiumHosting()))
        if c.chromium, let page = view.page { await page.chromiumStart?.value }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.window.cgColor
        let scope = ThemeScope(level: .workspace)
        scope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [c.newTab ? .newTabPage : .agentPane: ground]))
        scope.root(host)
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        window.orderFrontRegardless()
        view.applyTheme(force: true)
        view.layoutSubtreeIfNeeded()
        return (view, host, window, scope)
    }

    @Test(.timeLimit(.minutes(1)), arguments: cases)
    func aNewPanesChatShowsItsOwnGroundBeforeItsPageDraws(_ c: Case) async throws {
        let (view, host, window, scope) = try await pane(c, ground: SurfaceBackground(color: Self.chatGround, opacity: 1))
        defer { withExtendedLifetime(scope) {}; view.page?.close(); window.close() }
        try #require(!view.model.hasPainted, "the page painted: the test no longer reaches the frames before its first paint")
        try #require(view.pageContent.alphaValue == 0, "the page shows: the test no longer reaches the frames before its first paint")

        let middle = try Self.pixel(of: host, at: CGPoint(x: 200, y: 150))
        #expect(middle == Self.rgb(Self.chatGround),
                "the new pane shows \(middle) before its page draws, not the chat's own ground \(Self.rgb(Self.chatGround)) (\(Self.rgb(Self.window)): the window colour)")

        // The row the chat shares with its pane's tabs (the view lies under the strip then) has no backing.
        view.setTabRowCover(40)
        view.needsLayout = true
        let row = try Self.pixel(of: host, at: CGPoint(x: 200, y: 280))
        #expect(row == Self.rgb(Self.window), "the shared tab row shows \(row): a backing behind the pane's tabs")
        let below = try Self.pixel(of: host, at: CGPoint(x: 200, y: 20))
        #expect(below == Self.rgb(Self.chatGround), "under the shared row the pane shows \(below), not the chat's ground")
    }

    /// A translucent ground (the window's glass shows through the page) is not painted twice: the pane shows what it
    /// showed before, the window's sheet.
    @Test(.timeLimit(.minutes(1)))
    func aTranslucentChatGroundLeavesTheAreaAsItWas() async throws {
        let (view, host, window, scope) = try await pane(Case(chromium: false, newTab: true), ground: SurfaceBackground(color: Self.chatGround, opacity: 0.5))
        defer { withExtendedLifetime(scope) {}; view.page?.close(); window.close() }
        let middle = try Self.pixel(of: host, at: CGPoint(x: 200, y: 150))
        #expect(middle == Self.rgb(Self.window), "a half-clear chat ground painted \(middle) under its page")
    }
}
