import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21: "this vertical ellipsis is slow" (the sidebar group's ⋮ and its editor). A
/// click on a group's or workspace's ⋮, or a right-click on either row, shows its popup within
/// a frame or so: the main thread's work before the first frame stays under 50 ms, cold or warm.
@MainActor @Suite(.serialized)
struct SidebarMenuOpenLatencyTests {
    static let budget = 50.0

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// The main thread's CPU time and the wall time for `body` (PaletteOpenLatencyTests: other
    /// jobs on a shared runner delay the wall clock, not the CPU time).
    private static func measure(_ body: () -> Void) -> (cpu: Double, wall: Double) {
        func now() -> Duration {
            var spent = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spent)
            return .seconds(spent.tv_sec) + .nanoseconds(spent.tv_nsec)
        }
        let clock = ContinuousClock()
        let started = now(), wallStart = clock.now
        body()
        return (milliseconds(now() - started), milliseconds(clock.now - wallStart))
    }

    private static func report(_ name: String, _ samples: [(cpu: Double, wall: Double)]) -> (cold: Double, warm: Double) {
        let cold = samples[0].cpu
        let warm = samples.dropFirst().map(\.cpu).sorted()[(samples.count - 1) / 2]
        let wall = samples.dropFirst().map(\.wall).sorted()[(samples.count - 1) / 2]
        print("menu-open-latency \(name): cold \(String(format: "%.1f", cold)) ms cpu (\(String(format: "%.1f", samples[0].wall)) wall), "
            + "warm median \(String(format: "%.1f", warm)) ms cpu (\(String(format: "%.1f", wall)) wall)")
        return (cold, warm)
    }

    /// The group ⋮: from the press to the editor bubble's first frame committed, in a window on screen.
    @Test func theGroupMoreButtonOpensItsEditorWithinTheBudget() throws {
        let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red, .blue, .green])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sidebar.list.groupEditor.hide(); window.close() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        window.orderFront(nil)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        var samples: [(cpu: Double, wall: Double)] = []
        for round in 0..<9 {
            let id = ids[round % ids.count]
            let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
            header.isHovered = true
            header.layoutSubtreeIfNeeded()
            let more = header.moreButton
            samples.append(Self.measure {
                _ = more.sendAction(more.action, to: more.target)
                CATransaction.flush()
            })
            #expect(sidebar.list.groupEditor.shownGroup == id)
            sidebar.list.groupEditor.hide()
            sidebar.list.groupEditor.bubble?.resetPopupScale()
        }
        let (cold, warm) = Self.report("group ⋮ editor", samples)
        #expect(cold < Self.budget * 2, "the first group editor took \(cold) ms")
        #expect(warm < Self.budget, "the group editor took \(warm) ms")
    }

    private static func appMenu(_ target: SidebarContextTarget, services: AppServices) throws -> NSMenu {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [SidebarNode] = [
            .group(SidebarGroup(id: GroupID("lat-g"), name: "cmux-next app", color: .blue,
                                workspaces: (0..<4).map { SidebarWorkspace(id: WorkspaceID("lat-in-\($0)"), title: "w\($0)") })),
            .workspace(SidebarWorkspace(id: WorkspaceID("lat-ws"), title: "api")),
        ]
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("lat-ws"))
        let menu = try #require(SidebarContextMenus.menu(for: target, model: model, services: services, scope: ThemeScope(level: .room)))
        // The menu's size lays out every row view, as its first frame does.
        _ = menu.size
        return menu
    }

    /// The workspace and group right-click menus (and the workspace ⋮, which shows the same
    /// menu): building and laying out the menu before AppKit draws it.
    @Test(arguments: ["workspace", "group"])
    func theRowMenuIsBuiltWithinTheBudget(kind: String) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let target: SidebarContextTarget = kind == "workspace" ? .workspaces([WorkspaceID("lat-ws")]) : .group(GroupID("lat-g"))
        var samples: [(cpu: Double, wall: Double)] = []
        for _ in 0..<9 {
            samples.append(Self.measure { _ = try? Self.appMenu(target, services: services) })
        }
        let (cold, warm) = Self.report("\(kind) right-click menu", samples)
        #expect(cold < Self.budget * 2, "the first \(kind) menu took \(cold) ms")
        #expect(warm < Self.budget, "the \(kind) menu took \(warm) ms")
    }
}
