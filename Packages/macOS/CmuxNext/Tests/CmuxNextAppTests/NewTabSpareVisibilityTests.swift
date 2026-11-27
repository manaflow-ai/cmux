import AppKit
import CmuxNextDaemon
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// A late chats.page answer invalidates the first cover after the spare has gone to sleep.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSpareVisibilityTests {
    @Test func aParkedSpareWakesForItsReplacementCoverAndSleepsAgain() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            window.orderFrontRegardless()
            let pool = services.newTabSpares
            pool.dropAll()
            let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-visibility-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html")
            try Data("<html><body>New Tab capture fixture</body></html>".utf8).write(to: file)
            var nextFrames: [() -> Void] = []
            var snapshots: [NSImage] = []
            var fixtureView: AgentPaneView?
            var adoptedView: AgentPaneView?
            let captureID = UUID().uuidString
            defer {
                pool.makeSpare = nil
                pool.dropAll()
                adoptedView?.close()
                for frame in nextFrames { frame() }
                // Release test-owned captures while late tasks finish, without falling back to
                // the real compositor after the fixture has closed.
                fixtureView?.redraw.nextFrameOverride = { $0() }
                fixtureView?.redraw.snapshotOverride = { nil }
                try? FileManager.default.removeItem(at: directory)
            }
            // An inert page cannot race the synthetic chats answer with a real bridge response.
            // Drive frame and snapshot delivery, but keep the pool's real ownership callbacks.
            pool.makeSpare = { page in
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                AgentPaneNewTabFrame.shared.pageMade(model)
                AgentPaneNewTabFrame.shared.chatsAnswered(
                    .init(chats: [], nextCursor: nil, ready: true, enabled: true, design: captureID),
                    query: .init(text: nil, cursor: nil, limit: 50), to: model)
                guard let view = AgentPaneView(model: model, source: .bundled(file)) else { return nil }
                fixtureView = view
                view.redraw.nextFrameOverride = { nextFrames.append($0) }
                view.redraw.snapshotOverride = { [weak view] in
                    guard let view else { return nil }
                    let image = NSImage(size: view.frame.size, flipped: false) { rect in
                        NSColor.red.setFill()
                        rect.fill()
                        return true
                    }
                    snapshots.append(image)
                    return image
                }
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ pool.spare != nil })
            let view = try #require(pool.spare?.view), host = try #require(view.superview)
            // The first remembered cover also uses the injected snapshot, with no compositor.
            view.model.markPainted()
            try await PasswordManagerRouteTests.until({ !snapshots.isEmpty })
            #expect(!view.isHidden, "the parked spare must keep its renderer warm after its cover is captured")
            let frames = AgentPaneNewTabFrame.shared
            let appearance = host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let initial = try #require(snapshots.last)
            #expect(view.redraw.takeRememberedFrame(size: view.frame.size, appearance: appearance) === initial)
            // A first-page response arrives after the initial cover was taken.
            frames.chatsAnswered(.init(chats: [], nextCursor: nil, ready: true, enabled: true, design: captureID + "-replacement"),
                                 query: .init(text: nil, cursor: nil, limit: 50), to: view.model)
            #expect(frames.image(size: host.bounds.size, appearance: appearance) == nil)
            let beforeReplacement = snapshots.count
            frames.capture(view, in: host)
            #expect(view.redraw.givesNewTabFrame)
            #expect(!view.isHidden, "the replacement cover cannot be captured from a suspended renderer")
            try await PasswordManagerRouteTests.until({ !nextFrames.isEmpty })
            nextFrames.removeFirst()()
            try await PasswordManagerRouteTests.until({ !view.redraw.givesNewTabFrame })
            #expect(!view.isHidden, "the replacement cover must leave the parked renderer warm")
            let cover = try #require(frames.image(size: host.bounds.size, appearance: appearance))
            #expect(cover.isValid && cover.size == host.bounds.size, "the replacement must be a usable cover")
            try #require(snapshots.count == beforeReplacement + 2)
            #expect(cover === snapshots[beforeReplacement], "the shared cover must be the replacement snapshot")
            #expect(view.redraw.takeRememberedFrame(size: view.frame.size, appearance: appearance) === snapshots.last,
                    "the parked page must remember its replacement cover while staying warm")

            // Adoption during another capture invalidates its eventual sleep callback.
            frames.chatsAnswered(.init(chats: [], nextCursor: nil, ready: true, enabled: true, design: captureID + "-adoption"),
                                 query: .init(text: nil, cursor: nil, limit: 50), to: view.model)
            frames.capture(view, in: host)
            #expect(!view.isHidden)
            try await PasswordManagerRouteTests.until({ !nextFrames.isEmpty })
            let adopted = try #require(pool.take(for: window, size: view.frame.size)?.view)
            adoptedView = adopted
            #expect(adopted === view)
            #expect(view.redraw.newTabFrameCaptureChanged == nil)
            nextFrames.removeFirst()()
            try await PasswordManagerRouteTests.until({ !view.redraw.givesNewTabFrame })
            #expect(!view.isHidden, "a late capture hid the adopted page")
        }
    }
}
