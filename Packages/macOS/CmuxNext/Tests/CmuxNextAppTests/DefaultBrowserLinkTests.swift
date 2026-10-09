import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import Testing

/// cx-k9go: Open Link in Default Browser hands the link to the app macOS
/// opens web links with, and is left out of the menu (and refused) while
/// that app is cmux itself.
@MainActor @Suite(.serialized) struct DefaultBrowserLinkTests {
    static let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    static let link: [String: ActionValue] = ["url": .string("https://example.com/a")]

    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        DefaultBrowserLink.bind(into: registry)
        return registry
    }

    private func rows(_ registry: ActionRegistry) -> [String] {
        registry.makeContextMenu(for: .browserLink, target: ActionTargetRef(kind: .tab, id: "t"),
                                 entries: [.action("openLinkInDefaultBrowser")], arguments: Self.link).items.map(\.title)
    }

    @Test func anotherDefaultBrowserOpensTheLink() {
        var opened: [(URL, URL)] = []
        let saved = (DefaultBrowserLink.handler, DefaultBrowserLink.open)
        defer { (DefaultBrowserLink.handler, DefaultBrowserLink.open) = saved }
        DefaultBrowserLink.handler = { _ in .init(appURL: Self.safari, isCmux: false) }
        DefaultBrowserLink.open = { opened.append(($0, $1)) }
        let registry = registry()
        #expect(rows(registry) == ["Open Link in Default Browser"])
        registry.perform("openLinkInDefaultBrowser", invocation: ActionInvocation(arguments: Self.link))
        #expect(opened.map(\.0.absoluteString) == ["https://example.com/a"])
        #expect(opened.map(\.1) == [Self.safari])
    }

    @Test func cmuxAsTheDefaultBrowserLeavesTheRowOut() {
        var opened = 0
        let saved = (DefaultBrowserLink.handler, DefaultBrowserLink.open)
        defer { (DefaultBrowserLink.handler, DefaultBrowserLink.open) = saved }
        DefaultBrowserLink.handler = { _ in .init(appURL: Bundle.main.bundleURL, isCmux: true) }
        DefaultBrowserLink.open = { _, _ in opened += 1 }
        let registry = registry()
        #expect(rows(registry).isEmpty)
        registry.perform("openLinkInDefaultBrowser", invocation: ActionInvocation(arguments: Self.link))
        #expect(opened == 0)
    }

    @Test func theRunningBundleIsCmux() {
        #expect(DefaultBrowserLink.isCmux(Bundle.main.bundleURL, main: .main))
        #expect(!DefaultBrowserLink.isCmux(Self.safari, main: .main) || Bundle.main.bundleIdentifier == "com.apple.Safari")
    }
}
