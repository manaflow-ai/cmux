import Foundation
import JavaScriptCore
import Testing
@testable import CmuxBrowser

/// Regression coverage for https://github.com/manaflow-ai/cmux — the address-bar
/// focus tracker used to stamp `data-cmux-addressbar-focus-id` onto focused inputs
/// via `setAttribute`, which mutated server-rendered DOM nodes and broke
/// React/Next.js hydration on localhost dev pages. Focus identity now lives in an
/// in-page WeakMap registry, so capture must not touch the DOM while capture →
/// restore still round-trips.
@Suite struct BrowserOmnibarPageFocusScriptsTests {
    /// Minimal DOM stand-in. `getAttribute` always returns null and
    /// `querySelector` never matches, so any code that relies on the focus-id
    /// attribute (the old behavior) cannot recover the element — only the registry
    /// can.
    private func makeContextWithMockDOM() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            Issue.record("Unexpected JS exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(
            """
            var window = {};
            window.top = window;
            var __setAttrCalls = [];
            var el = {
              tagName: "INPUT",
              type: "text",
              isContentEditable: false,
              isConnected: true,
              value: "hello",
              selectionStart: 1,
              selectionEnd: 3,
              __focused: false,
              getAttribute: function () { return null; },
              setAttribute: function (name) { __setAttrCalls.push(name); },
              focus: function () { this.__focused = true; document.activeElement = this; },
              matches: function () { return this.__focused; },
              setSelectionRange: function (start, end) { this.__selStart = start; this.__selEnd = end; }
            };
            var document = {
              activeElement: el,
              querySelector: function () { return null; },
              querySelectorAll: function () { return []; },
              addEventListener: function () {}
            };
            el.ownerDocument = document;
            """
        )
        return context
    }

    @Test func captureDoesNotWriteFocusIdAttributeToDOM() {
        let context = makeContextWithMockDOM()

        let result = context.evaluateScript(BrowserOmnibarPageFocusRepository.captureScript)?.toString() ?? ""
        #expect(
            result.hasPrefix("captured:"),
            "capture should record the focused editable element; got \(result)"
        )

        let setAttrCalls = context.evaluateScript("__setAttrCalls.join(',')")?.toString() ?? ""
        #expect(
            !setAttrCalls.contains("data-cmux-addressbar-focus-id"),
            "focus tracking must not write data-cmux-addressbar-focus-id to the DOM (it regressed React hydration); setAttribute calls were: \(setAttrCalls)"
        )

        let stateId = context.evaluateScript("(window.__cmuxAddressBarFocusState || {}).id || \"\"")?.toString() ?? ""
        #expect(!stateId.isEmpty, "capture should still produce a focus-state id")
    }

    @Test func captureThenRestoreRoundTripsViaRegistry() {
        let context = makeContextWithMockDOM()

        _ = context.evaluateScript(BrowserOmnibarPageFocusRepository.captureScript)
        // Clear focus so restore must re-find the element through the registry
        // rather than reading document.activeElement or a DOM attribute selector.
        context.evaluateScript("el.__focused = false; document.activeElement = null;")

        let restored = context.evaluateScript(BrowserOmnibarPageFocusRepository.restoreScript)?.toString()
        #expect(
            restored == "restored",
            "focus restore must find the element via the registry without the DOM attribute"
        )

        let selStart = context.evaluateScript("el.__selStart")?.toInt32()
        let selEnd = context.evaluateScript("el.__selEnd")?.toInt32()
        #expect(selStart == 1, "restore should reapply the captured selection start")
        #expect(selEnd == 3, "restore should reapply the captured selection end")
    }
}
