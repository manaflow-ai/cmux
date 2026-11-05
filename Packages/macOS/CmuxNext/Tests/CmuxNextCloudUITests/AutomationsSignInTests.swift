import AppKit
@testable import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import Testing

/// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". The
/// Automations page's "Sign in to cmux to see your Cloud automations." line shows the shared Sign In
/// button when the app gives the page a sign-in, and only on that line.
@MainActor @Suite(.serialized) struct AutomationsSignInTests {
    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    @Test func onlyCloudsSignedOutLineOffersSignIn() {
        let actions = AutomationsPageView.Actions(signIn: {})
        #expect(AutomationsPageView.signIn(for: .cloud, code: "automation.signed_out", actions: actions) != nil)
        #expect(AutomationsPageView.signIn(for: .cloud, code: "unreachable", actions: actions) == nil)
        #expect(AutomationsPageView.signIn(for: .thisMac, code: "automation.signed_out", actions: actions) == nil)
        #expect(AutomationsPageView.signIn(for: .cloud, code: "automation.signed_out", actions: .init()) == nil)
    }

    /// Renders the signed-out page before (text only) and after (with Sign In), light and dark, to one
    /// PNG (`$CMUX_SIGNIN_SHOTS/automations-signed-out.png`, else `.build/artifacts/`).
    @Test func rendersSignedOutBeforeAndAfter() async throws {
        let page = AutomationsPage(local: { Data("[]".utf8) },
                                   cloud: { throw AutomationsPageHost.SourceError(code: "automation.signed_out", message: "") })
        await page.reload(now: .now)
        #expect(page.problems[.cloud] == "automation.signed_out")
        let lightInput = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))
        let darkInput = ThemeInput(background: ThemeRGB(hex: 0x1E1E20), foreground: ThemeRGB(hex: 0xF2F2F7))
        let themes = [(ThemeTokens.derive(from: lightInput), lightInput, "Sign In Light", NSAppearance.Name.aqua),
                      (ThemeTokens.derive(from: darkInput), darkInput, "Sign In Dark", NSAppearance.Name.darkAqua)]
        let rows = [AutomationsPageView.Actions(), AutomationsPageView.Actions(signIn: {})]  // before, after
        // Each page draws in its own theme scope, as a page in a light or dark theme does, so the AppKit
        // Sign In button takes the page's colors. The registry holds a view's scope weakly: keep them.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1192, height: 416))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.gray.cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var scopes: [ThemeScope] = []
        defer { withExtendedLifetime(scopes) {} }
        for (row, actions) in rows.enumerated() {
            for (column, theme) in themes.enumerated() {
                let scope = ThemeScope(level: .room)
                scope.setOverride(try #require(ThemeSpec(theme.2)), input: theme.1, animated: false)
                scopes.append(scope)
                let pane = AutomationsPageView(page: page, palette: AutomationsPalette(tokens: theme.0), actions: actions)
                pane.appearance = NSAppearance(named: theme.3)
                pane.frame = NSRect(x: 24 + CGFloat(column) * 584, y: 232 - CGFloat(row) * 208, width: 560, height: 160)
                host.addSubview(pane)
                scope.root(pane)
                let buttons = Self.descendants(of: pane).compactMap { $0 as? SignInButton }
                #expect(buttons.count == (row == 0 ? 0 : 1), "the signed-out line offers Sign In only when the app gives one")
            }
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(!Self.descendants(of: host).contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
        let dir = ProcessInfo.processInfo.environment["CMUX_SIGNIN_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../.build/artifacts").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("automations-signed-out.png"))
    }
}
