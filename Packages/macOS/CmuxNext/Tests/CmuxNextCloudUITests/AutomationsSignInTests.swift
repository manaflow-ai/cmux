import AppKit
@testable import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import SwiftUI
import Testing

/// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". The
/// Automations page's "Sign in to cmux to see your Cloud automations." line shows the shared Sign In
/// button when the app gives the page a sign-in, and only on that line.
@MainActor @Suite(.serialized) struct AutomationsSignInTests {
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
        let light = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F)))
        let dark = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E20), foreground: ThemeRGB(hex: 0xF2F2F7)))
        let actions = AutomationsPageView.Actions(signIn: {})
        let before = AutomationsPageView.Actions()
        let lightPalette = AutomationsPalette(tokens: light), darkPalette = AutomationsPalette(tokens: dark)
        let top = HStack(spacing: 24) {
            AutomationsPageView(page: page, palette: lightPalette, actions: before).frame(width: 560, height: 160).environment(\.colorScheme, .light)
            AutomationsPageView(page: page, palette: darkPalette, actions: before).frame(width: 560, height: 160).environment(\.colorScheme, .dark)
        }
        let bottom = HStack(spacing: 24) {
            AutomationsPageView(page: page, palette: lightPalette, actions: actions).frame(width: 560, height: 160).environment(\.colorScheme, .light)
            AutomationsPageView(page: page, palette: darkPalette, actions: actions).frame(width: 560, height: 160).environment(\.colorScheme, .dark)
        }
        let view = VStack(spacing: 24) { top; bottom }.padding(24).background(Color.gray)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1192, height: 416)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = ProcessInfo.processInfo.environment["CMUX_SIGNIN_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../.build/artifacts").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("automations-signed-out.png"))
    }
}
