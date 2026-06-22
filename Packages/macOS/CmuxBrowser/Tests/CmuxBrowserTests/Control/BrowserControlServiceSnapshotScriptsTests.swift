import Foundation
import Testing
@testable import CmuxBrowser

/// Locks the byte-shape of the `browser.snapshot` DOM-walk script lifted from
/// `TerminalController`'s `v2BrowserSnapshot` body into ``BrowserControlService``.
///
/// The full script is ~170 lines; these expectations pin the interpolated header
/// (every flag/depth/scope option the caller passes in), the load-bearing
/// structural anchors that drive the role classification and tree walk, and the
/// returned payload shape, so a drift in any of the interpolation points or the
/// option wiring fails the test.
@Suite("BrowserControlService snapshot script")
struct BrowserControlServiceSnapshotScriptsTests {
    let service = BrowserControlService()

    @Test("header interpolates every snapshot option verbatim")
    func headerInterpolation() {
        let script = service.snapshotScript(
            interactiveLiteral: "true",
            cursorLiteral: "false",
            compactLiteral: "true",
            maxDepth: 8,
            scopeLiteral: "\"#root\""
        )
        #expect(script.hasPrefix("""
        (() => {
          const __interactiveOnly = true;
          const __includeCursor = false;
          const __compact = true;
          const __maxDepth = 8;
          const __scopeSelector = "#root";
        """))
    }

    @Test("null scope selector is spliced as the bare null token")
    func nullScope() {
        let script = service.snapshotScript(
            interactiveLiteral: "false",
            cursorLiteral: "false",
            compactLiteral: "false",
            maxDepth: 12,
            scopeLiteral: "null"
        )
        #expect(script.contains("const __scopeSelector = null;"))
    }

    @Test("structural anchors and returned payload shape are preserved")
    func structuralAnchors() {
        let script = service.snapshotScript(
            interactiveLiteral: "false",
            cursorLiteral: "true",
            compactLiteral: "false",
            maxDepth: 12,
            scopeLiteral: "null"
        )
        // Role classification sets that drive entry inclusion.
        #expect(script.contains("const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);"))
        // The CSS-path nth-of-type disambiguation.
        #expect(script.contains("part += `:nth-of-type(${index})`;"))
        // The click-affordance cursor sweep cap.
        #expect(script.contains("if (__entries.length >= 256) break;"))
        // The returned payload keys.
        #expect(script.contains("ready_state: String(document.readyState || ''),"))
        #expect(script.contains("entries: __entries"))
        #expect(script.hasSuffix("})()"))
    }
}
