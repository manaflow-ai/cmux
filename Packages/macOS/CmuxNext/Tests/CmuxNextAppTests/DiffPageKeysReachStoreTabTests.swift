import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDiff
@testable import CmuxNextPages
import Foundation
import Testing

/// Cmd-= in a diff tab showed "No diff viewer has the keyboard." and left the code at its size
/// (fleet capture of f3e09e83, 2026-11-20: the key dispatcher chose `diffViewerZoomIn`, the
/// handler refused). Where the daemon holds page tabs (page-tabs-v1, every local daemon), a diff
/// tab's strip id is the daemon's tab id, and the diff service keys its page by the page's own key
/// (`services.pages.storeKey(of:)` maps one to the other). The diff handler looked the page up by
/// the strip id, so none of the 14 `diffViewer*` keys (zoom, next file, search...) reached it.
@MainActor @Suite(.serialized, .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct DiffPageKeysReachStoreTabTests {
    @Test func diffKeysReachTheFocusedAndTheTargetedStoreDiffTab() async throws {
        // The test bundle has no built webviews-app: a scratch root serves the page's document, so
        // the tab gets its real page view (the first registration per process wins).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-diffkeys-root-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["index.html", PageDescriptor.diffEntry] {
            try Data("<html><body></body></html>".utf8).write(to: root.appendingPathComponent(name))
        }
        PageID.registerBundledRoot(root, for: PageDescriptor.diff.id)
        try await PasswordManagerRouteTests.withApp { services, _ in
            let pane = try #require(services.windows.active?.focusedPane)
            let pages = services.viewers.diffPages
            let key = pages.open(repository: DiffRepository(root: "/tmp/cn-diffkeys-repo", branch: nil, base: nil),
                                 gitLink: services.agentGit.link(for: services.daemon), in: pane, focus: true, on: services.daemon)
            // The strip tab that shows the diff, in whichever pane the open put it.
            @MainActor func shown() -> (pane: PaneController, id: String)? {
                for controller in services.windows.controllers {
                    for candidate in controller.content?.panes.values.map({ $0 }) ?? [] {
                        if let id = candidate.stripModel.tabs.map(\.id.rawValue).first(where: { FilePageHandlers.providerKey($0, services) == key }) {
                            return (candidate, id)
                        }
                    }
                }
                return nil
            }
            try await PasswordManagerRouteTests.until({ shown() != nil }, report: { "the diff tab did not open" })
            let (host, tabID) = try #require(shown())
            // What this test is about: a store page tab, whose strip id is not the page's key.
            #expect(tabID != key, "the diff opened as an app-only tab; this test needs a store page tab")
            // A headless test window never draws the tab: the pane shows it here, as on screen,
            // which makes its page view.
            if host.stripModel.selectedID?.rawValue != tabID, let strip = host.stripModel.tabs.first(where: { $0.id.rawValue == tabID }) {
                host.select(strip.id)
            }
            if host.currentContent == nil { host.showSelected() }
            try await PasswordManagerRouteTests.until({ pages.pageView(key) != nil }, report: { "the diff tab has no page view" })
            let router = try #require(pages.pageView(key)).router

            // Stand in for the page's script: subscribe to its command stream and record what arrives.
            var commands: [String] = []
            router.sendWithDrop = nil
            router.send = { envelope in
                if let command = envelope["data"]?["command"]?.stringValue { commands.append(command) }
            }
            let reply = await router.handle(["t": "sub", "id": 9002, "stream": .string(PageNativeOp.pageCommand)])
            #expect(reply["t"]?.stringValue == "ok")

            let actions = ["diffViewerZoomIn", "diffViewerZoomOut", "diffViewerZoomReset", "diffViewerNextFile"]
            let expected = actions.compactMap { DiffPageCommand.forAction[$0] }
            #expect(expected.count == actions.count)
            // The keyboard's path: the focused pane's selected tab.
            let content = try #require(host.workspace)
            PaneHandlers.focus(host.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({ services.windows.active?.focusedPane === host },
                                                      report: { "the diff tab's pane did not take focus" })
            for action in actions {
                #expect(services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user)),
                        "\(action) on the focused diff tab")
            }
            #expect(commands.filter { $0 != PageNativeOp.focusContent } == expected)
            // The palette's and CLI's path: the tab named as the target.
            commands.removeAll()
            let target = ActionTargetRef(kind: .tab, id: tabID)
            for action in actions {
                #expect(services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(target: target, origin: .cli)),
                        "\(action) on the targeted diff tab")
            }
            #expect(commands.filter { $0 != PageNativeOp.focusContent } == expected)
        }
    }
}
