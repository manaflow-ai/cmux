import CmuxNextDaemon
import Testing

/// The LARGE session as a store fixture (plans/cmux-next/main-thread-scheduling.md 1.5): the shape of
/// scripts/cmux-next/perf-stress-session.py `build_large`, 60 workspaces x 6 tabs, one pane each (3 terminals, 1 agent
/// chat, 1 Chromium page, 1 WebKit page), and the title streams of 5 hidden workspaces as `titleChanged` events: a
/// spinner glyph every frame, a new text every 25 frames.
///
/// Step 0 adds the fixture only. Its cases come with steps 3 and 4, each red first in its own PR: (a) a spinner-only
/// title change wakes 0 observations, (b) a text change wakes only observations of that tab and its workspace, (c) no
/// observation outside a list owner is woken by changes in more than one workspace (``ObservationWakes``).
///
/// Not `LargeSessionFixture`: that name is the one shared 60 x 6 store fixture of #40126 (MTS-4 O2), which the row
/// tests use. This one keeps its own shape (one pane per workspace) and the title streams, so any merge order compiles.
struct LargeSessionTitleStreamFixture {
    static let workspaces: UInt64 = 60
    static let tabsPerWorkspace: UInt64 = 6
    /// The workspaces whose first terminal streams titles (0-based, as perf-stress-session.py TITLE_STREAM_WORKSPACES).
    static let streamWorkspaces: [UInt64] = [0, 12, 24, 36, 48]
    static let spinner = Array("\u{280B}\u{2819}\u{2839}\u{2838}\u{283C}\u{2834}\u{2826}\u{2827}\u{2807}\u{280F}")
    static let framesPerText = 25

    /// The surface id of tab `index` (0..<6) of workspace `workspace` (0..<60): unique, from 1.
    static func surface(workspace: UInt64, index: UInt64) -> SurfaceID {
        SurfaceID(rawValue: workspace * tabsPerWorkspace + index + 1)
    }

    /// The tree: per workspace one screen, one pane, tabs in LARGE_MIX order.
    static func tree() -> DaemonTree {
        DaemonTree(workspaces: (0..<workspaces).map { workspace in
            let tabs = (0..<tabsPerWorkspace).map { index in tab(surface(workspace: workspace, index: index), index: index) }
            let paneID = PaneID(rawValue: workspace + 1)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: workspace + 1), layout: .leaf(paneID), panes: [PaneSnapshot(id: paneID, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: workspace + 1), key: nil, name: "large \(workspace + 1)", screens: [screen])
        })
    }

    private static func tab(_ id: SurfaceID, index: UInt64) -> TabSnapshot {
        switch index {
        case 3:
            var chat = TabSnapshot(surface: id, kind: .conversation, title: "chat")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: "s-\(id.rawValue)", harness: "claude"))
            return chat
        case 4:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "cef")
        case 5:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "webkit")
        default:
            return TabSnapshot(surface: id, kind: .pty, title: "~")
        }
    }

    /// `frames` frames of every title stream, interleaved as they arrive (one event per stream per frame).
    static func titleEvents(frames: Int) -> [DaemonEvent] {
        (0..<frames).flatMap { frame in
            streamWorkspaces.map { workspace in
                .titleChanged(surface: surface(workspace: workspace, index: 0),
                              title: "\(spinner[frame % spinner.count]) agent task \(frame / framesPerText)")
            }
        }
    }
}

@MainActor
struct LargeSessionTitleStreamTests {
    /// The fixture is the LARGE shape, and its 5 x 100 title events reach the store (the cases of steps 3 and 4 count
    /// the observations they wake).
    @Test func theFixtureIsTheLargeSessionAndItsTitleStreamsApply() throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: LargeSessionTitleStreamFixture.tree())
        #expect(store.workspaces.count == 60)
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        #expect(tabs.count == 360)
        let events = LargeSessionTitleStreamFixture.titleEvents(frames: 100)
        #expect(events.count == 500)
        for event in events { _ = store.apply(event) }
        let streamed = LargeSessionTitleStreamFixture.streamWorkspaces.map {
            LargeSessionTitleStreamFixture.surface(workspace: $0, index: 0)
        }
        for surface in streamed {
            let tab = try #require(tabs.first { $0.surface == surface })
            #expect(tab.title.hasSuffix("agent task 3"), "stream \(surface.rawValue): title \(tab.title)")
        }
    }
}
