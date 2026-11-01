import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextTerminal
import Foundation
import Testing

/// #26079: the actual Ghostty click and open_url paths must use the configured browser,
/// even when AppKit's last dequeued event carries different modifiers.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalLinkRoutingTests {
    @Test(arguments: [
        "https://github.com/manaflow-ai/cmux/pull/26079",
        "https://example.com/docs",
    ])
    func terminalClicksFollowSettingsAndOnlyTheirOwnModifiers(_ text: String) async throws {
        let h = try TerminalCmdClickLinkTests.Harness()
        defer { h.close() }
        let services = AppServices(environment: AppEnvironment.current([:]))
        var opened: [LinkRouting.Target] = []
        var nextOpen: ((LinkRouting.Target) -> Void)?
        let router = LinkRouter(openSystemURL: { url in
            #expect(url.absoluteString == text)
            opened.append(.system)
            nextOpen?(.system)
        })
        let delegate = TerminalHostDelegate(linkRouter: router)
        delegate.services = services
        router.openInCmux = { url, _, _ in
            #expect(url.absoluteString == text)
            opened.append(.cmuxBrowser)
            nextOpen?(.cmuxBrowser)
        }
        h.session.delegate = delegate
        try await h.output(text + "\r\n", showing: text)
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil)

        let cases: [(json: String, flags: NSEvent.ModifierFlags?, stale: NSEvent.ModifierFlags, expected: LinkRouting.Target)] = [
            ("{}", .command, [.command, .shift], .cmuxBrowser),
            (#"{"browser":{"openLinksInCmuxBrowser":false}}"#, .command, [.command, .shift], .system),
            (#"{"browser":{"openLinksInCmuxBrowser":false}}"#, .command, [.command, .option], .system),
            (#"{"browser":{"enabled":false}}"#, .command, [.command, .shift], .system),
            (#"{"browser":{"urlsToAlwaysOpenExternally":["*"]}}"#, .command, [.command, .shift], .system),
            (#"{"browser":{"urlsToAlwaysOpenExternally":["bank.example"]}}"#, .command, [.command, .shift], .cmuxBrowser),
            (#"{"browser":{"hostsToOpenInEmbeddedBrowser":["localhost"]}}"#, .command, [.command, .shift], .system),
            // Intentional Shift-Command still picks the other target, in either direction.
            ("{}", [.command, .shift], .command, .system),
            (#"{"browser":{"openLinksInCmuxBrowser":false}}"#, [.command, .shift], .command, .cmuxBrowser),
            (#"{"browser":{"enabled":false}}"#, [.command, .shift], .command, .system),
            // A programmatic open_url has no click modifiers to inherit.
            ("{}", nil, [.command, .shift], .cmuxBrowser),
            (#"{"browser":{"openLinksInCmuxBrowser":false}}"#, nil, [.command, .option], .system),
        ]
        for item in cases {
            let config = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(item.json.utf8)), validDensities: [], validMetrics: [])
            #expect(config.diagnostics.isEmpty)
            router.routing = { config.linkRouting }
            if let flags = item.flags {
                try await h.hover(5, 0, flags)
                try #require(h.session.model.hoveredLink == text)
            }
            let (events, continuation) = AsyncStream<LinkRouting.Target>.makeStream(bufferingPolicy: .bufferingNewest(1))
            nextOpen = { continuation.yield($0); continuation.finish() }
            let stale = try Self.click(flags: item.stale)
            let previousEvent = NSApp.currentEvent
            // Only the synchronous dispatch sees this stale event; other async tests never do.
            do {
                NSApp.setValue(stale, forKey: "currentEvent")
                defer { NSApp.setValue(previousEvent, forKey: "currentEvent") }
                if let flags = item.flags {
                    services.inputDispatch.dispatching(try Self.click(flags: flags)) {
                        h.session.clickLinkForTesting(column: 5, row: 0, flags: flags)
                    }
                } else {
                    #expect(h.session.activateLink(text))
                }
            }
            var iterator = events.makeAsyncIterator()
            let destination = await iterator.next()
            nextOpen = nil
            #expect(destination == item.expected, "routing \(item.json) with click \(String(describing: item.flags))")
        }
        #expect(opened == cases.map(\.expected), "each activation must open exactly once")
    }

    private static func click(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
}
