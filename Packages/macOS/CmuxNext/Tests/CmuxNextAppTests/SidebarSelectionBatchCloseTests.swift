import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing
import UniformTypeIdentifiers

/// Leo 2026-10-21, closing several selected sidebar workspaces (#23110's Cmd-W on a selection):
/// "also idk what's going on with these new workspace deletions but it's really slow and it's
/// missing a LOT... and it's also 2 lines tall for some reason". Each selected row ran its own
/// Close Workspace: its own sidebar pass, its own question, and its own turn in the window's lane
/// waiting for the daemon and the store before the next row started. A selection closes as one
/// batch now: one question covers them all (asked while the rows stay put), every row leaves in one
/// pass, every close goes out at once, and "Closed N workspaces" with Undo brings them all back. Runs on a same-tree cmux-tui
/// daemon and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarSelectionBatchCloseTests {
    private static let toastID = "workspaces-closed"

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    /// `count` new workspaces in the active window, named `prefix-NN`, once its sidebar lists them all.
    private static func make(_ count: Int, prefix: String, command: String? = nil, _ services: AppServices,
                             in controller: WindowController) async throws -> [String] {
        var ids: [String] = []
        for index in 1...count {
            ids.append(try await services.windows.createWorkspace(WorkspaceSpawn(name: String(format: "\(prefix)-%02d", index), command: command),
                                                                into: controller.state.id))
        }
        let sidebar = controller.sidebar.model
        try await PinnedPageTests.until({ Set(sidebar.selectableWorkspaces.map(\.id.rawValue)).isSuperset(of: ids) }, within: .seconds(60),
                                        report: { "listed \(sidebar.selectableWorkspaces.count) rows" })
        return ids
    }

    /// Whether a close of `ids` keeps its rows until the question is answered (`WorkspaceBulkClose.mayAsk`),
    /// read from the store as the press reads it.
    private static func keepsRows(_ ids: [String], _ services: AppServices) -> Bool {
        WorkspaceBulkClose.mayAsk(ids.compactMap { services.machines.workspace(id: $0) }, warn: true)
    }

    /// Whether `id`'s row is listed in `sidebar` and not closing (it has not started to animate out).
    private static func shown(_ id: String, in sidebar: SidebarModel) -> Bool {
        sidebar.allWorkspaces.contains { $0.id.rawValue == id } && !ClosingWorkspaces.shared.ids.contains(id)
    }

    private static func listed(_ ids: [String], _ services: AppServices) -> [String] {
        ids.filter { services.workspace(id: $0) != nil }
    }

    @Test func fiftySelectedWorkspacesCloseTogetherAndUndoBringsThemAllBack() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(50, prefix: "bulk", services, in: controller)
            let notices = Notices()
            let shows = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in
                if !quiet { notices.shown.append(reason) }
                shows?(reason, quiet)
            }
            defer { services.registry.refusalObserver = shows }

            // The sidebar's Delete key on the selection (Cmd-W and the row menu's Close send the same intent).
            let sidebar = controller.sidebar.model
            sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
            // Shells at their prompt (OSC 133) leave at the press; a host whose shells report none keeps the
            // rows for the terminals' process-info answer (WorkspaceCloseFlow).
            let instant = !Self.keepsRows(ids, services)
            // What a parallel run does: the host's cores are busy (other tests' daemons and renderers), so the
            // daemon commits each close slower. Three spinning threads per core for 20 s.
            let load = CPULoad(seconds: 20)
            defer { load.stop() }
            let pressed = ContinuousClock.now
            let work = services.registry.capturingWork { sidebar.send(.close(sidebar.orderedSelection)) }
            let pressHeld = ContinuousClock.now - pressed
            let leftAtPress = ids.filter { id in sidebar.allWorkspaces.contains { $0.id.rawValue == id } }

            try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(90))
            let closed = ContinuousClock.now - pressed
            for task in work { print("SidebarSelectionBatchClose: the batch's failure: \(String(describing: await task.value))") }
            let missed = Self.listed(ids, services)
            try? await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == Self.toastID } }, within: .seconds(5))
            let toasts = CmuxToastCenter.shared.toasts(in: window)
            print("SidebarSelectionBatchClose: 50 rows, press held the main actor \(pressHeld), all closed after \(closed), "
                + "missed \(missed.count), toasts \(toasts.map(\.message)), notices \(notices.shown)")

            if instant { #expect(leftAtPress.isEmpty, "rows still shown right after the press: \(leftAtPress.count)") }
            #expect(missed.isEmpty, "not closed: \(missed.count) of 50")
            #expect(notices.shown.isEmpty, "notices: \(notices.shown)")
            // One toast for the whole close, on one line of its own: no refusal beside it.
            #expect(toasts.map(\.message) == ["Closed 50 workspaces"], "toasts: \(toasts.map(\.message))")

            let undone = ContinuousClock.now
            #expect(CmuxToastCenter.shared.runAction(id: Self.toastID, in: window))
            let names = Set((1...50).map { String(format: "bulk-%02d", $0) })
            @MainActor func reopened() -> Set<String> { Set(services.daemon.store.workspaces.map { $0.name }).intersection(names) }
            try? await PinnedPageTests.until({ reopened().count == names.count }, within: .seconds(60))
            print("SidebarSelectionBatchClose: undo reopened \(reopened().count) of 50 after \(ContinuousClock.now - undone)")
            #expect(reopened() == names, "not reopened: \(names.subtracting(reopened()).sorted())")
        }
    }

    /// The row menu's Close (and Cmd-W) on one of several selected rows: a selection with running
    /// programs asks one question for all of it, and Close closes every row.
    @Test func aSelectionWithRunningProgramsAsksOnceAndClosesEveryRow() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let idle = try await Self.make(6, prefix: "idle", services, in: controller)
            let busy = try await Self.make(3, prefix: "busy", command: "sleep 600", services, in: controller)
            let ids = idle + busy
            try await PinnedPageTests.until({ Self.keepsRows(busy, services) }, within: .seconds(30))
            let sidebar = controller.sidebar.model
            sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
            let opened = Notices()
            let dialogs = CmuxDialogCenter.shared
            let token = dialogs.observe { event in if case .opened(let record) = event { opened.shown.append(record.spec.title) } }
            defer { dialogs.stopObserving(token) }

            #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: ids[0]))))
            // The rows stay put while the terminals answer and while the question is up: none animates out first.
            #expect(ids.allSatisfy { Self.shown($0, in: sidebar) })
            try await PinnedPageTests.until({ !dialogs.records.isEmpty }, within: .seconds(20))
            #expect(ids.allSatisfy { Self.shown($0, in: sidebar) }, "rows left before the question was answered")
            // Every row's question would be up by now (process-info answers within a second).
            try? await Task.sleep(for: .seconds(3))
            let asked = opened.shown.count
            for record in dialogs.records where record.spec.identifier == "cmux.dialog.confirmation" {
                _ = dialogs.press(record.id, button: DestructiveConfirmation.confirmID)
            }
            try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(60))
            print("SidebarSelectionBatchClose: 9 rows (3 running sleep) asked \(asked) questions, missed \(Self.listed(ids, services).count)")
            #expect(asked == 1, "questions asked: \(asked)")
            #expect(Self.listed(ids, services).isEmpty, "not closed: \(Self.listed(ids, services).count) of 9")
        }
    }

    /// Close Workspace on a workspace running a program (the row's close button, Cmd-Shift-W, the
    /// menu): the question shows first and the row stays put; Cancel keeps it, Close then removes it.
    /// Before, the row animated out at the press and the question came up after it.
    @Test func aRunningWorkspaceAsksBeforeItsRowMovesAndCancelKeepsIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            _ = try await Self.make(1, prefix: "keep", services, in: controller)
            let id = try #require(try await Self.make(1, prefix: "running", command: "sleep 600", services, in: controller).first)
            let sidebar = controller.sidebar.model
            // Its terminal is in the store (the row can list before its tab): the press reads it there.
            try await PinnedPageTests.until({ Self.keepsRows([id], services) }, within: .seconds(30), report: {
                let member = services.machines.workspace(id: id)
                let tabs = member?.0.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
                return "live \(member?.1.isLive == true), tabs \(tabs.map { "\($0.kind) dead=\($0.dead) prompt=\(String(describing: $0.promptSinceMs)) command=\(String(describing: $0.commandSinceMs))" })"
            })
            let dialogs = CmuxDialogCenter.shared
            @MainActor func question() -> CmuxDialogCenter.Record? { dialogs.records.first { $0.spec.identifier == "cmux.dialog.confirmation" } }

            // The row's close button sends this intent.
            sidebar.send(.close([CmuxNextSidebar.WorkspaceID(id)]))
            #expect(Self.shown(id, in: sidebar), "the row left at the press")
            try await PinnedPageTests.until({ question() != nil }, within: .seconds(20))
            #expect(Self.shown(id, in: sidebar), "the row left before the question was answered")
            _ = dialogs.press(try #require(question()).id, button: "cancel")
            try await PinnedPageTests.until({ !WorkspaceCloseFlow.running.contains(id) }, within: .seconds(5))
            #expect(Self.shown(id, in: sidebar), "Cancel did not keep the row")
            #expect(services.workspace(id: id) != nil)

            // Again, and Close: the row leaves only now, and the workspace closes.
            sidebar.send(.close([CmuxNextSidebar.WorkspaceID(id)]))
            try await PinnedPageTests.until({ question() != nil }, within: .seconds(20))
            #expect(Self.shown(id, in: sidebar))
            _ = dialogs.press(try #require(question()).id, button: DestructiveConfirmation.confirmID)
            try await PinnedPageTests.until({ services.workspace(id: id) == nil }, within: .seconds(30))
            #expect(!sidebar.allWorkspaces.contains { $0.id.rawValue == id })
        }
    }

    /// The row still leaves on the close animation when the person takes a while to answer. Rows move on a spring
    /// only within `SidebarModel.userIntentWindow` (2 s) of the person's input (calm-sidebar-movement); a close
    /// that waits on its question hides the row after that, so without a fresh mark at the hide its row would
    /// drop out in one step. The sidebar's clock runs 3 s ahead from the question on: an answer 3 s later.
    @Test func aRowClosedAfterASlowAnswerStillAnimatesOut() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            _ = try await Self.make(1, prefix: "keep", services, in: controller)
            let id = try #require(try await Self.make(1, prefix: "slow", command: "sleep 600", services, in: controller).first)
            try await PinnedPageTests.until({ Self.keepsRows([id], services) }, within: .seconds(30))
            let sidebar = controller.sidebar.model, list = controller.sidebar.container.sidebarView.list
            let dialogs = CmuxDialogCenter.shared
            @MainActor func question() -> CmuxDialogCenter.Record? { dialogs.records.first { $0.spec.identifier == "cmux.dialog.confirmation" } }
            let clock = sidebar.userIntentClock
            defer { sidebar.userIntentClock = clock }
            // The host's Reduce Motion must not stand in for the regression (it snaps every row).
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }

            sidebar.send(.close([CmuxNextSidebar.WorkspaceID(id)]))
            try await PinnedPageTests.until({ question() != nil }, within: .seconds(20))
            sidebar.userIntentClock = { clock() + .seconds(3) }
            #expect(!sidebar.followsUserIntent, "the press's mark still counts 3 s later: the test proves nothing")
            let animates = SidebarInsertWhileDisplayAsleepTests.animatesHere() && Motion.sidebar.animatesMovement
            var closingSeen = false, intentAtHide = false
            _ = dialogs.press(try #require(question()).id, button: DestructiveConfirmation.confirmID)
            try await PinnedPageTests.until({
                // The turn the row starts to leave: the sidebar must still read it as the person's change.
                if ClosingWorkspaces.shared.ids.contains(id) || services.workspace(id: id) == nil, !intentAtHide {
                    intentAtHide = sidebar.followsUserIntent
                }
                if list.subviews.contains(where: { ($0 as? SidebarRowView)?.closingEnd != nil }) { closingSeen = true }
                return services.workspace(id: id) == nil
            }, within: .seconds(30))
            print("SidebarSelectionBatchClose: slow answer, intent at hide \(intentAtHide), animates here \(animates), closing row seen \(closingSeen)")
            #expect(intentAtHide, "the row left after a slow answer without the person's intent: it drops out with no animation")
            // With motion available here (an awake display, animations on), the row is seen on its closing spring.
            if animates { #expect(closingSeen, "the row left in one step, with no close animation") }
        }
    }

    /// Leo 2026-10-31, after a sidebar close of 8 rows showed "The workspace could not be closed." above
    /// "Closed 8 workspaces  Undo": "plus the dumb shit when it apparently races a delete". A close of a
    /// workspace the daemon no longer has (closed before it came, or by another close that committed while
    /// it was on its way) is a close that went through, never a refusal; a real refusal still fails.
    @Test func closingAWorkspaceThatIsAlreadyGoneIsNoRefusal() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let ids = try await Self.make(8, prefix: "race", services, in: controller)
            let keys = try ids.map { try #require(services.workspace(id: $0)?.key) }

            // Two closes of each at once (a second press, another window, the CLI): one of each pair commits first.
            let failures = await withTaskGroup(of: String?.self) { group in
                for key in keys + keys {
                    group.addTask {
                        do { try await WorkspaceClose.close(key, terminals: [], on: connection); return nil } catch { return "\(key.rawValue): \(error)" }
                    }
                }
                var failures: [String] = []
                for await failure in group { if let failure { failures.append(failure) } }
                return failures
            }
            #expect(failures.isEmpty, "closes that raced a close failed: \(failures)")
            // And once more, after the daemon has dropped them all.
            for key in keys {
                do { try await WorkspaceClose.close(key, terminals: [], on: connection) } catch {
                    Issue.record("a close of the already closed \(key.rawValue) failed: \(error)")
                }
            }

            // A genuine refusal still surfaces: `ifEmpty` on a workspace that has a tab.
            let kept = try await Self.make(1, prefix: "kept", services, in: controller)
            let key = try #require(services.workspace(id: kept[0])?.key)
            try await PinnedPageTests.until({ services.workspace(id: kept[0])?.screens.flatMap(\.panes).contains { !$0.tabs.isEmpty } == true }, within: .seconds(30))
            await #expect(throws: (any Error).self) { try await WorkspaceClose.close(key, terminals: [], on: connection, ifEmpty: true) }
            #expect(services.workspace(id: kept[0]) != nil)
        }
    }

    /// The same race through a selection's batch close: three of its eight rows are deleted while the batch
    /// still lists them (their delete is on its way to the store). The batch shows its one toast, "Closed 8
    /// workspaces", and no "The workspace could not be closed." above it.
    @Test func aBatchCloseThatRacesADeleteShowsOneToast() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(8, prefix: "raced", services, in: controller)
            let members = ids.compactMap { services.machines.workspace(id: $0) }
            try #require(members.count == 8)
            for (workspace, _) in members.prefix(3) { try await connection.closeWorkspace(try #require(workspace.key), endTerminals: true) }

            let offered = Notices()
            let flow = WorkspaceSelectionCloseFlow(
                hide: { InstantClose.begin($0, in: controller.state.id, windows: services.windows) }, mayAsk: { false }, question: { nil },
                restore: {}, listed: { _ in true }, machines: { services.machines.daemons },
                offerUndo: { names, _ in offered.shown.append(WorkspaceBulkClose.closedToast(names.count)) },
                window: controller.state.id, toastWindow: window, running: WorkspaceSelectionCloseFlow.Running())
            let work = try #require(flow.start(members))
            let failure = await work.value
            let toasts = CmuxToastCenter.shared.toasts(in: window)
            print("SidebarSelectionBatchClose: raced batch failure \(String(describing: failure)), toasts \(toasts.map(\.message)), offered \(offered.shown)")

            #expect(failure == nil, "the batch failed: \(String(describing: failure))")
            #expect(!toasts.contains { $0.id == "workspace-close-refused" }, "a refusal toast beside the batch's: \(toasts.map(\.message))")
            #expect(offered.shown == [WorkspaceBulkClose.closedToast(8)], "toasts offered: \(offered.shown)")
            try await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(30))
        }
    }

    /// The picture of the raced batch close for the PR (Leo's two stacked toasts before, one after): the window's
    /// bottom left (sidebar and toasts) at 2x, light above dark, in `.build/raced-batch-close.png` (a fleet step
    /// returns it with `--artifact`). The toasts are the app's own (`offerUndo` and the refusal path as the sidebar
    /// wires them); it checks only that a toast drew.
    @Test func aRacedBatchCloseCapture() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            var shots: [CGImage] = []
            // Rows that stay, so the sidebar beside the toasts is not empty.
            _ = try await Self.make(3, prefix: "web-app", services, in: controller)
            for (round, dark) in [false, true].enumerated() {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.appearance = NSApp.appearance
                // The chrome follows the cmux theme, not the appearance (as the sidebar galleries set it).
                _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input(dark ? "Soft Blue" : "Soft Blue Light"))
                let ids = try await Self.make(8, prefix: round == 0 ? "api-server" : "docs-site", services, in: controller)
                let members = ids.compactMap { services.machines.workspace(id: $0) }
                try #require(members.count == 8)
                for (workspace, _) in members.prefix(3) { try await connection.closeWorkspace(try #require(workspace.key), endTerminals: true) }
                let closing = members.map(\.0.id), context = AppActionContext(services: services)
                let undoWindow = WorkspaceBulkClose.survivor(closing: closing, context)
                let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
                let flow = WorkspaceSelectionCloseFlow(
                    hide: { InstantClose.begin($0, in: controller.state.id, windows: services.windows) }, mayAsk: { false }, question: { nil },
                    restore: {}, listed: { _ in true }, machines: { services.machines.daemons },
                    offerUndo: { names, undone in
                        guard names.count > 1, let undoWindow else { return }
                        WorkspaceGroupClose.offerUndo("workspaces-closed", WorkspaceBulkClose.closedToast(names.count), groups: [(nil, names)],
                                                      after: seen, in: undoWindow, services, undone: undone)
                    },
                    window: controller.state.id, toastWindow: window, running: WorkspaceSelectionCloseFlow.Running())
                let work = try #require(flow.start(members))
                _ = await work.value
                try? await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == Self.toastID } }, within: .seconds(10))
                try? await Task.sleep(for: .seconds(1)) // the toasts' appear motion
                print("SidebarSelectionBatchClose: capture \(dark ? "dark" : "light") toasts \(CmuxToastCenter.shared.toasts(in: window).map(\.message))")
                shots.append(try #require(Self.shot(window)))
                // The dark round's toasts take the light round's places (same ids): Undo's offer is throttled per id.
            }
            let width = shots.map(\.width).max() ?? 0, gap = 24, height = shots.map(\.height).reduce(0, +) + gap
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(shots[0], in: CGRect(x: 0, y: height - shots[0].height, width: shots[0].width, height: shots[0].height))
            ctx.draw(shots[1], in: CGRect(x: 0, y: 0, width: shots[1].width, height: shots[1].height))
            let out = AddServerShotsTests.packageRoot.appending(path: ".build/raced-batch-close.png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            print("SidebarSelectionBatchClose: wrote \(out.path)")
        }
    }

    /// `view`'s `rect` at 2x.
    private static func render(_ view: NSView, _ rect: NSRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    /// The window's content with its toasts drawn over it where they show (they live in the window's overlay
    /// panel), cropped to the bottom left: the sidebar and the toasts. Nil when no toast is found.
    private static func shot(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        func toasts(in view: NSView) -> [CmuxToastView] { (view as? CmuxToastView).map { [$0] } ?? view.subviews.flatMap { toasts(in: $0) } }
        let panels = NSApp.windows.filter { $0 !== window && ($0.parent === window || $0.parent?.parent === window) }
        let found = panels.compactMap(\.contentView).flatMap { toasts(in: $0.superview ?? $0) }.filter { !$0.isHidden && $0.alphaValue > 0 }
        var placed: [(CmuxToastView, NSRect)] = found.compactMap { toast in
            guard let host = toast.window else { return nil }
            var rect = content.convert(window.convertFromScreen(host.convertToScreen(toast.convert(toast.bounds, to: nil))), from: nil)
            if content.isFlipped { rect.origin.y = bounds.height - rect.maxY }
            return (toast, rect)
        }
        if placed.isEmpty {
            // No overlay panel in this run: the window's toasts, bottom centered and stacked as the toast host places them.
            var y: CGFloat = 24
            for toast in CmuxToastCenter.shared.toasts(in: window) {
                let view = CmuxToastView(toast: toast)
                view.appearance = window.effectiveAppearance
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                placed.append((view, NSRect(x: bounds.midX - size.width / 2, y: y, width: size.width, height: size.height)))
                y += size.height + 8
            }
        }
        print("SidebarSelectionBatchClose: capture found \(found.count) toast views in \(panels.count) panels, drew \(placed.count)")
        guard !placed.isEmpty, let base = render(content, bounds),
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CG's origin is bottom left; a flipped content view drew top down into its bitmap the same way.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for (view, rect) in placed {
            guard let image = render(view, view.bounds) else { continue }
            ctx.draw(image, in: CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2))
        }
        let top = (placed.map(\.1.maxY).max() ?? 0) + 260, right = (placed.map(\.1.maxX).max() ?? 0) + 48
        let crop = CGRect(x: 0, y: CGFloat(base.height) - min(top, bounds.height) * 2, width: min(right, bounds.width) * 2, height: min(top, bounds.height) * 2)
        return ctx.makeImage()?.cropping(to: crop)
    }
}

/// Spinning threads that take the host's cores, as a parallel run of the whole target does (evidence only).
private final class CPULoad: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    init(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount * 3) {
            Thread.detachNewThread { [self] in
                var x = 0.0
                while self.isRunning, Date() < end { x += 1 }
                _ = x
            }
        }
    }

    private var isRunning: Bool { lock.withLock { running } }
    func stop() { lock.withLock { running = false } }
}
