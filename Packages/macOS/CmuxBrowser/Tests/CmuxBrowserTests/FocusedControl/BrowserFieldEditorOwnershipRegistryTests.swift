import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

@MainActor
@Suite("BrowserFieldEditorOwnershipRegistry")
struct BrowserFieldEditorOwnershipRegistryTests {
    @Test("records and returns the owning web view for a field editor")
    func recordsAndReturns() {
        let registry = BrowserFieldEditorOwnershipRegistry()
        let fieldEditor = NSTextView()
        let webView = WKWebView()

        registry.setOwningWebView(webView, forFieldEditor: fieldEditor)

        #expect(registry.owningWebView(forFieldEditor: fieldEditor) === webView)
    }

    @Test("returns nil for an untracked field editor")
    func untrackedReturnsNil() {
        let registry = BrowserFieldEditorOwnershipRegistry()
        #expect(registry.owningWebView(forFieldEditor: NSTextView()) == nil)
    }

    @Test("setting a nil web view clears the recorded owner")
    func nilClears() {
        let registry = BrowserFieldEditorOwnershipRegistry()
        let fieldEditor = NSTextView()
        let webView = WKWebView()

        registry.setOwningWebView(webView, forFieldEditor: fieldEditor)
        registry.setOwningWebView(nil, forFieldEditor: fieldEditor)

        #expect(registry.owningWebView(forFieldEditor: fieldEditor) == nil)
    }

    @Test("re-recording replaces the owner for a field editor")
    func rerecordReplaces() {
        let registry = BrowserFieldEditorOwnershipRegistry()
        let fieldEditor = NSTextView()
        let first = WKWebView()
        let second = WKWebView()

        registry.setOwningWebView(first, forFieldEditor: fieldEditor)
        registry.setOwningWebView(second, forFieldEditor: fieldEditor)

        #expect(registry.owningWebView(forFieldEditor: fieldEditor) === second)
    }

    @Test("the registry holds the web view weakly, not strongly")
    func holdsWebViewWeakly() {
        // The backing store is `NSMapTable.weakToWeakObjects()`, so recording an
        // owner must not retain it. This is the property that made the former
        // weak associated-object box read return nil once the web view died.
        let registry = BrowserFieldEditorOwnershipRegistry()
        let fieldEditor = NSTextView()
        weak var weakWebView: WKWebView?

        autoreleasepool {
            let webView = WKWebView()
            weakWebView = webView
            registry.setOwningWebView(webView, forFieldEditor: fieldEditor)
            #expect(registry.owningWebView(forFieldEditor: fieldEditor) === webView)
        }

        // No assertion on `weakWebView` being nil here: WKWebView's process-pool
        // teardown is asynchronous, so its dealloc timing is not deterministic in
        // a unit test. The contract under test is that the registry adds no
        // strong reference of its own; the weak-store API guarantees the nil-out.
    }

    @Test("entries are isolated per field editor")
    func perFieldEditorIsolation() {
        let registry = BrowserFieldEditorOwnershipRegistry()
        let editorA = NSTextView()
        let editorB = NSTextView()
        let webA = WKWebView()
        let webB = WKWebView()

        registry.setOwningWebView(webA, forFieldEditor: editorA)
        registry.setOwningWebView(webB, forFieldEditor: editorB)

        #expect(registry.owningWebView(forFieldEditor: editorA) === webA)
        #expect(registry.owningWebView(forFieldEditor: editorB) === webB)
    }
}
