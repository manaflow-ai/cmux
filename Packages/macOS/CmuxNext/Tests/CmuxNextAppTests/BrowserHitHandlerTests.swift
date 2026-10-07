import AppKit
import CmuxNextActions
import CmuxNextBrowser
import Testing
@testable import CmuxNextApp

/// The link and selection copy rows through the real handlers (the palette,
/// the CLI and MCP run the same ones). The pasteboard is a fake: fleet test
/// steps run with no pasteboard server.
@MainActor
@Suite struct BrowserHitHandlerTests {
    nonisolated final class FakePasteboard: BrowserPasteboard {
        var urls: [String] = []
        var texts: [String] = []
        func writePageURL(_ url: URL) { urls.append(url.absoluteString) }
        func writeText(_ text: String) { texts.append(text) }
        func writeImage(_ image: NSImage, source: URL) {}
    }

    private func make(_ board: FakePasteboard) -> ActionRegistry {
        let services = AppServices(environment: AppEnvironment.current([:]))
        BrowserHitHandlers.bind(into: services.registry, context: AppActionContext(services: services), pasteboard: { board })
        return services.registry
    }

    private func run(_ registry: ActionRegistry, _ id: ActionID, _ arguments: [String: ActionValue]) -> String? {
        registry.capturingRefusal {
            _ = registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: "tab-1"), arguments: arguments))
        }
    }

    @Test func copyRowsWriteTheHit() {
        let board = FakePasteboard()
        let registry = make(board)
        #expect(run(registry, "browser.link.copy", ["url": .string("https://example.com/a")]) == nil)
        #expect(run(registry, "browser.image.copyAddress", ["url": .string("https://example.com/cat.png")]) == nil)
        #expect(run(registry, "browser.link.copyText", ["url": .string("https://example.com/a"), "text": .string("The docs")]) == nil)
        #expect(run(registry, "browser.selection.copy", ["text": .string("picked")]) == nil)
        #expect(board.urls == ["https://example.com/a", "https://example.com/cat.png"])
        #expect(board.texts == ["The docs", "picked"])
    }

    /// An address must have a scheme and never be `javascript:`.
    @Test func badAddressesAreRefused() {
        let board = FakePasteboard()
        let registry = make(board)
        #expect(run(registry, "browser.link.copy", ["url": .string("not a url")]) == BrowserHitStrings.urlRequired)
        #expect(run(registry, "browser.link.openInNewTab", ["url": .string("javascript:alert(1)")]) == BrowserHitStrings.urlRequired)
        #expect(board.urls.isEmpty)
    }
}
