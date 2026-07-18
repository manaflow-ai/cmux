import CmuxRemoteSession
// DEBUG-only socket verbs that exist solely for the UI test suite.
//
// They live in this dedicated file (never compiled into release — see the
// #if DEBUG wrapping the whole extension) because the XCUITest runner is
// SANDBOXED: it cannot create directories under /tmp, spawn a tmux server
// there, or resize app windows without AX gestures — while the unsandboxed
// app can. @testable import cannot cross that process boundary, so the tests
// drive these two verbs over the app's own debug socket instead.

#if DEBUG
import AppKit
import Darwin
import Foundation

extension TerminalController {
    /// `remote.tmux.test_exec` (DEBUG only) — runs a tmux argv with a given
    /// `TMUX_TMPDIR` inside the APP process and returns its exit/stdout/stderr.
    ///
    /// Exists solely so the sandboxed XCUITest runner can build and drive a
    /// hermetic lab tmux server WITHOUT touching the filesystem itself: the
    /// runner is confined to its container and cannot create `/tmp` dirs or
    /// spawn a tmux there, but the unsandboxed app can — so the runner sends
    /// every `new-session`/`split-window`/`resize-pane`/`list-panes` through
    /// this one socket verb, and the app owns the whole lab lifecycle in a
    /// path both its own tmux commands AND its ssh-shim attach can reach.
    /// Never compiled into release.
    nonisolated func v2RemoteTmuxTestExec(id: Any?, params: [String: Any]) -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_MODE"] == "1",
              let tmpdir = params["tmpdir"] as? String,
              tmpdir == environment["TMUX_TMPDIR"]
        else {
            return v2Error(
                id: id,
                code: "unavailable",
                message: "remote.tmux.test_exec is restricted to its UI-test tmux directory"
            )
        }
        // JSON arrays arrive as [Any] (NSString elements), not [String] —
        // compactMap through Any so the cast never silently fails.
        guard let rawArgs = params["args"] as? [Any] else {
            return v2Error(id: id, code: "invalid_params", message: "args is required")
        }
        let args = rawArgs.compactMap { $0 as? String }
        guard args.count == rawArgs.count, !args.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "args must be non-empty strings")
        }
        guard Self.isAllowedRemoteTmuxTestCommand(args) else {
            return v2Error(id: id, code: "invalid_params", message: "tmux command is not allowed")
        }
        // Only known tmux install paths: in allowAll socket mode this verb is
        // reachable by any local user, so it must not be a generic exec.
        let allowedBins: Set<String> = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let bin = (params["bin"] as? String) ?? "/opt/homebrew/bin/tmux"
        guard allowedBins.contains(bin) else {
            return v2Error(id: id, code: "invalid_params", message: "bin must be a known tmux path")
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            try FileManager.default.createDirectory(atPath: tmpdir, withIntermediateDirectories: true)
            var env = environment
            env["TMUX_TMPDIR"] = tmpdir
            env.removeValue(forKey: "TMUX")
            let result = try await self.runBoundedRemoteTmuxTestCommand(
                executable: bin,
                arguments: ["-f", "/dev/null"] + args,
                environment: env
            )
            return [
                "exit": Int(result.status),
                "stdout": result.stdout,
                "stderr": result.stderr,
            ]
        }
    }

    /// Exact non-executing tmux grammar required by `RemoteTmuxSizingUITests`.
    /// Targets and names never reach a shell; formats are pinned because tmux
    /// format strings can themselves execute `#()` commands.
    nonisolated static func isAllowedRemoteTmuxTestCommand(_ args: [String]) -> Bool {
        func isAtom(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "._-:@%".unicodeScalars.contains($0)
            }
        }
        func isDimension(_ value: String) -> Bool {
            guard let number = Int(value) else { return false }
            return (1...10_000).contains(number)
        }
        guard let command = args.first else { return false }
        switch command {
        case "kill-server":
            return args.count == 1
        case "new-session":
            let base = args.count == 8 || args.count == 10
            return base && args[1] == "-d" && args[2] == "-s" && isAtom(args[3])
                && args[4] == "-x" && isDimension(args[5])
                && args[6] == "-y" && isDimension(args[7])
                && (args.count == 8 || (args[8] == "-n" && isAtom(args[9])))
        case "split-window":
            return args.count == 4 && ["-h", "-v"].contains(args[1])
                && args[2] == "-t" && isAtom(args[3])
        case "select-layout":
            return args.count == 4 && args[1] == "-t" && isAtom(args[2])
                && ["even-horizontal", "even-vertical", "tiled", "main-horizontal"].contains(args[3])
        case "new-window":
            return (args.count == 3 || args.count == 5)
                && args[1] == "-t" && isAtom(args[2])
                && (args.count == 3 || (args[3] == "-n" && isAtom(args[4])))
        case "select-window":
            return args.count == 3 && args[1] == "-t" && isAtom(args[2])
        case "set":
            return args.count == 6 && args[1] == "-w" && args[2] == "-t"
                && isAtom(args[3]) && args[4] == "pane-border-status"
                && ["top", "bottom"].contains(args[5])
        case "resize-pane":
            // `-Z` toggles zoom; `-x`/`-y` set a dimension.
            if args.count == 4 && args[1] == "-Z" && args[2] == "-t" && isAtom(args[3]) {
                return true
            }
            return args.count == 5 && args[1] == "-t" && isAtom(args[2])
                && ["-x", "-y"].contains(args[3]) && isDimension(args[4])
        case "resize-window":
            return args.count == 7 && args[1] == "-t" && isAtom(args[2])
                && args[3] == "-x" && isDimension(args[4])
                && args[5] == "-y" && isDimension(args[6])
        case "kill-pane":
            return args.count == 3 && args[1] == "-t" && isAtom(args[2])
        case "select-pane":
            return args.count == 3 && args[1] == "-t" && isAtom(args[2])
        case "capture-pane":
            return args.count == 5 && args[1] == "-p" && args[2] == "-J"
                && args[3] == "-t" && isAtom(args[4])
        case "send-keys":
            // The content oracle's ruler is an arbitrary shell one-liner sent
            // as keystrokes. This verb is DEBUG-only and confined to the
            // UI-test tmux directory, so the payload (args[3]) is unconstrained;
            // only the target and the trailing Enter key are checked.
            return args.count == 5 && args[1] == "-t" && isAtom(args[2])
                && args[4] == "Enter"
        case "list-panes":
            return args.count == 5 && args[1] == "-t" && isAtom(args[2]) && args[3] == "-F"
                && ["#{pane_width}", "#{pane_id}", "#{pane_width} #{pane_top}"].contains(args[4])
        case "list-windows":
            return args.count == 5 && args[1] == "-t" && isAtom(args[2]) && args[3] == "-F"
                && args[4] == "#{window_id} #{window_name}"
        case "display-message":
            return args.count == 5 && args[1] == "-p" && args[2] == "-t"
                && isAtom(args[3]) && args[4] == "#{window_width}x#{window_height}"
        default:
            return false
        }
    }

    /// Runs one validated tmux command with structured cancellation and bounded
    /// capture. Cancellation terminates the child and closes both pipe readers,
    /// so the socket timeout cannot strand a process or an output task.
    private nonisolated func runBoundedRemoteTmuxTestCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = {
                continuation.yield($0.terminationStatus)
                continuation.finish()
            }
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            async let stdout = self.readBoundedRemoteTmuxTestOutput(stdoutHandle)
            async let stderr = self.readBoundedRemoteTmuxTestOutput(stderrHandle)
            do {
                try process.run()
            } catch {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                process.terminationHandler = nil
                throw error
            }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            var status: Int32?
            for await value in exits {
                status = value
                break
            }
            let output = try await (stdout, stderr)
            try Task.checkCancellation()
            guard let status else { throw CancellationError() }
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return (status, output.0, output.1)
        } onCancel: {
            if process.isRunning {
                process.terminate()
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
    }

    /// Drains a pipe to EOF while retaining at most 256 KiB.
    private nonisolated func readBoundedRemoteTmuxTestOutput(_ handle: FileHandle) async throws -> String {
        let limit = 256 * 1_024
        var data = Data()
        data.reserveCapacity(limit)
        var truncated = false
        for try await byte in handle.bytes {
            if data.count < limit {
                data.append(byte)
            } else {
                truncated = true
            }
        }
        var text = String(decoding: data, as: UTF8.self)
        if truncated { text += "\n[output truncated]" }
        return text
    }

    /// `remote.tmux.test_set_frame` (DEBUG only) — resizes and/or moves a
    /// cmux window to an exact frame from within the app. `width`/`height`
    /// resize (omitted = keep the current size); `x`/`y` place the frame
    /// origin in screen coordinates, so an x/y-only call is an origin-only
    /// MOVE — the geometry-only stimulus the sizing counters guard needs.
    ///
    /// Exists for the sizing UI tests: driving window frames with XCUITest
    /// mouse drags depends on the desktop around the app (an overlapping
    /// window from any other application invokes XCUITest's permission-dialog
    /// interruption scan, which crashes on elements whose accessibility value
    /// is numeric). `NSWindow.setFrame` drives the same resize path the
    /// window server does, deterministically. Never compiled into release.
    nonisolated func v2RemoteTmuxTestSetFrame(id: Any?, params: [String: Any]) -> String {
        guard let idString = params["window_id"] as? String,
              let windowId = UUID(uuidString: idString)
        else {
            return v2Error(id: id, code: "invalid_params", message: "window_id is required")
        }
        let width = params["width"] as? Double
        let height = params["height"] as? Double
        let originX = params["x"] as? Double
        let originY = params["y"] as? Double
        if width == nil, height == nil, originX == nil, originY == nil {
            return v2Error(
                id: id, code: "invalid_params",
                message: "at least one of width, height, x, y is required"
            )
        }
        if let width, width <= 100 {
            return v2Error(id: id, code: "invalid_params", message: "width must exceed 100")
        }
        if let height, height <= 100 {
            return v2Error(id: id, code: "invalid_params", message: "height must exceed 100")
        }
        // Generous timeout: the hop onto the main actor can wait out a busy
        // render/output burst in a test app running a dozen live panes.
        return v2VmCall(id: id, timeoutSeconds: 30) {
            // Read back the frame AFTER setFrame: AppKit clamps to min/max
            // content sizes and screen bounds, so the actual frame is the only
            // trustworthy answer — callers assert on it rather than assuming
            // the request applied.
            let applied: CGRect? = await MainActor.run { () -> CGRect? in
                guard let window = AppDelegate.shared?.windowForMainWindowId(windowId) else {
                    return nil
                }
                var frame = window.frame
                let newSize = CGSize(
                    width: width.map { CGFloat($0) } ?? frame.size.width,
                    height: height.map { CGFloat($0) } ?? frame.size.height
                )
                // Keep the top-left corner anchored so the window stays on screen.
                frame.origin.y += frame.size.height - newSize.height
                frame.size = newSize
                if let originX { frame.origin.x = CGFloat(originX) }
                if let originY { frame.origin.y = CGFloat(originY) }
                window.setFrame(frame, display: true, animate: false)
                return window.frame
            }
            guard let applied else {
                throw RemoteTmuxError.unreachable("window not found: \(idString)")
            }
            return [
                "applied_width": Double(applied.width),
                "applied_height": Double(applied.height),
                "applied_x": Double(applied.origin.x),
                "applied_y": Double(applied.origin.y),
            ]
        }
    }

    /// `remote.tmux.test_perturb_divider` (DEBUG only) — clears the visible
    /// mirror's root-split imposition and moves its divider to `position`,
    /// changing rendered geometry while every sizing input stays put. The
    /// deterministic stand-in for an apply that terminated off-target
    /// (bonsplit parking a divider at a minimum, a retry budget expiring
    /// against mid-commit bounds): the sizing UI suite fires this at a
    /// settled mirror and asserts it re-converges, pinning the liveness rule
    /// end to end — an apply may never stay off-target behind unchanged
    /// inputs. Never compiled into release.
    nonisolated func v2RemoteTmuxTestPerturbDivider(id: Any?, params: [String: Any]) -> String {
        let windowId = params["window"] as? Int ?? 0
        let position = params["position"] as? Double ?? 0.8
        guard position > 0, position < 1 else {
            return v2Error(id: id, code: "invalid_params", message: "position must be in (0, 1)")
        }
        return v2VmCall(id: id, timeoutSeconds: 15) {
            let result: [String: Any]? = await MainActor.run {
                for workspace in self.tabManager?.tabs ?? [] {
                    guard let session = workspace.remoteTmuxSessionMirror,
                          let mirror = session.windowMirrorByWindowId[windowId],
                          mirror.isEffectivelyVisibleForSizing,
                          case .split(let split) = mirror.bonsplitController.treeSnapshot(),
                          let splitId = UUID(uuidString: split.id) else { continue }
                    let before = split.dividerPosition
                    _ = mirror.bonsplitController.setImposedFirstExtent(
                        nil, forSplit: splitId, fromExternal: true
                    )
                    let moved = mirror.bonsplitController.setDividerPosition(
                        CGFloat(position), forSplit: splitId, fromExternal: true
                    )
                    // Drop the divider baseline so the geometry callback that
                    // follows the move SEEDS it instead of diffing against
                    // it — no resize-pane goes to tmux, so no layout echo
                    // changes a sizing input. Without this the scenario
                    // exercises drag propagation (tmux re-assigns, inputs
                    // change, the normal pass heals); with it, the only way
                    // back onto the plan is the output-parity re-arm.
                    mirror.lastDividerPositions[splitId] = nil
                    return [
                        "split": split.id,
                        "moved": moved,
                        "position_before": before,
                        "position_after": position,
                    ]
                }
                return nil
            }
            guard let result else {
                throw RemoteTmuxError.unreachable(
                    "no visible mirrored split window @\(windowId)"
                )
            }
            return result
        }
    }

    /// `remote.tmux.root_frames` (DEBUG only) — the window-versus-content
    /// truth the growth-spiral tripwire logs (`mirror.container.ancestors`),
    /// as data: for every visible mirror, the hosting window's frame and
    /// content-view sizes plus the widths of the mirror's real ancestor
    /// chain, probe to root. The sizing UI suite asserts the chain holds the
    /// window's width after settling. The live spiral kept every CLAIM sane
    /// (the oversized-reading guard dropped the inflated readings) while the
    /// content view marched a step wider per layout pass — a class no grid
    /// oracle can see, only the frames.
    nonisolated func v2RemoteTmuxRootFrames(id: Any?) -> String {
        v2VmCall(id: id, timeoutSeconds: 15) {
            let report: [[String: Any]] = await MainActor.run {
                var out: [[String: Any]] = []
                for workspace in self.tabManager?.tabs ?? [] {
                    guard let session = workspace.remoteTmuxSessionMirror else { continue }
                    for (windowId, mirror) in session.windowMirrorByWindowId {
                        guard mirror.isEffectivelyVisibleForSizing,
                              let probe = mirror.hostProbeView,
                              let window = probe.window else { continue }
                        let chain: [[String: Any]] = mirror.hostProbeAncestorChain().map {
                            [
                                "class": String($0.className.suffix(40)),
                                "width": Double($0.width),
                                "height": Double($0.height),
                            ]
                        }
                        out.append([
                            "window": windowId,
                            "window_width": Double(window.frame.width),
                            "window_height": Double(window.frame.height),
                            "content_layout_width": Double(window.contentLayoutRect.width),
                            "content_layout_height": Double(window.contentLayoutRect.height),
                            "content_view_width": Double(window.contentView?.frame.width ?? -1),
                            "content_view_height": Double(window.contentView?.frame.height ?? -1),
                            "ancestors": chain,
                        ])
                    }
                }
                return out
            }
            return ["windows": report]
        }
    }

    /// `remote.tmux.sizing_settled` (DEBUG only) — answers "has every
    /// mirrored window finished settling, and does every pane render exactly
    /// its assigned span?" in one call. Harnesses poll this instead of
    /// guessing with timers: a timer too short misreads transitions as bugs,
    /// too long crawls. `settled` means each mirror's tmux layout matches the
    /// size it claimed; `mismatches` lists panes whose last rendered grid
    /// differs from their assigned span. A mismatch while `settled` is true
    /// is a real rendering bug, no ambiguity.
    func remoteTmuxSizingSettlementPayload() -> [String: Any] {
        var windows: [[String: Any]] = []
        var connectionsConnected = true
        for workspace in self.tabManager?.tabs ?? [] {
            guard let session = workspace.remoteTmuxSessionMirror else { continue }
            let connected = session.connection.connectionState == .connected
            connectionsConnected = connectionsConnected && connected
            let liveWindowIds = Set(session.connection.windowOrder)
            // At most ONE mirror per session may own sizing — a workspace shows one
            // tab at a time. This is checked at the SESSION level because it cannot
            // be seen per-window: a mirror with a stale `visible == true` has
            // on_screen == false, so the per-window checks below skip it by design
            // (its panes are parked offscreen and judging their grids reports
            // phantoms). That blind spot is exactly half the defect this judge exists
            // for — the hide edge — so it is asserted here, where two owners are
            // countable, rather than left to a check that structurally cannot fail.
            let owners = session.windowMirrorByWindowId
                .filter { liveWindowIds.contains($0.key) && !$0.value.isTornDown }
                .filter { $0.value.isVisibleForSizing }
                .keys
                .sorted()
            if owners.count > 1 {
                windows.append([
                    "window": owners.first ?? -1,
                    "claimed": "none",
                    "settled": false,
                    "mismatches": [
                        "multiple mirrors own sizing: "
                            + owners.map { "@\($0)" }.joined(separator: ",")
                            + " — a switched-away mirror never released it",
                    ],
                ])
            }
            // A SOLE stale owner used to escape: one mirror keeps the flag while
            // hidden, the tab now selected is a single-pane window (which has no
            // mirror), so the count is 1, nothing is on screen, and no per-window
            // check fires. Check each owner against the product's own rule instead
            // of counting.
            //
            // The rule is `panelVisibleInUI`: isWorkspaceVisible && (isSelectedInPane
            // || isFocused). Its first two inputs are view-level — `isWorkspaceVisible`
            // and `isWorkspaceInputActive` are properties fed into the SwiftUI view, not
            // model state — so the full equality is not recomputable here. The
            // implication is: holding the flag REQUIRES the panel be selected in its
            // pane or focused, and both of those are model state. An owner that is
            // neither is stale, with no judgement needed about whether the workspace is
            // showing. Necessary-condition only, so it cannot fire on a legitimately
            // hidden-but-selected mirror — the case that makes the on-screen assertion
            // directional.
            let selectedPanelIds: Set<UUID> = Set(
                workspace.bonsplitController.allPaneIds
                    .compactMap { workspace.bonsplitController.selectedTab(inPane: $0)?.id }
                    .compactMap { workspace.panelIdFromSurfaceId($0) }
            )
            for windowId in owners {
                guard let mirror = session.windowMirrorByWindowId[windowId] else { continue }
                let isSelectedInPane = selectedPanelIds.contains(mirror.panelId)
                let isFocused = workspace.focusedPanelId == mirror.panelId
                guard !isSelectedInPane, !isFocused else { continue }
                windows.append([
                    "window": windowId,
                    "claimed": "none",
                    "settled": false,
                    "mismatches": [
                        "@\(windowId) owns sizing but its panel is neither selected in its"
                            + " pane nor focused — the flag outlived the hide edge",
                    ],
                ])
            }
            for (windowId, mirror) in session.windowMirrorByWindowId {
                // A window tmux no longer lists cannot settle and
                // must not be judged; its mirror is mid-teardown.
                guard liveWindowIds.contains(windowId) else { continue }
                guard !mirror.isTornDown else { continue }
                // Never GATE on isVisibleForSizing. This judge used to open with
                // `guard mirror.isEffectivelyVisibleForSizing else { continue }`,
                // which ANDs the flag with the view state — and being an AND it
                // could only SHRINK the judged set. A mirror whose flag lied was
                // therefore dropped from the report instead of failing it: the
                // defect blinded the judge rather than reddening it. Measured
                // live: the one window actually on screen reported visible=0 and
                // vanished from this list while a 125-iteration fuzz marathon
                // read green.
                //
                // The two terms are still both needed — judging a mirror whose
                // panes sit in the offscreen parking window reports phantom
                // mismatches — so compare them and report the disagreement.
                // Read view state HERE rather than through a mirror helper: the
                // point is that this judge must not depend on the mirror's own
                // notion of visibility, which is exactly the thing under test.
                let onScreen = mirror.panelsByPaneId.values.contains { panel in
                    let hostedView = panel.hostedView
                    return hostedView.isVisibleInUI
                        && !hostedView.isHidden
                        && hostedView.superview != nil
                        && hostedView.window?.isVisible == true
                }
                let claimed = mirror.connection?.lastWindowSizes[windowId]
                var mismatches: [String] = []
                // Directional on purpose. A window whose panes are ON SCREEN must
                // own its sizing: if it does not, nothing derives its claim and it
                // renders at whatever tmux last gave it — the defect this judge
                // exists to catch.
                //
                // The converse is NOT a defect and must not be asserted:
                // isVisibleForSizing tracks the tab being SELECTED within its
                // window to be ordered in. A selected tab in a cmux window that
                // sits behind another window is legitimately flag=1, on_screen=0.
                // Asserting equality here reported that ordinary state as a
                // contradiction on every iteration.
                if onScreen, !mirror.isVisibleForSizing {
                    mismatches.append(
                        "on screen but not visible-for-sizing"
                            + " container=\(Self.sizeDescription(mirror.containerSizePt))"
                            + " claimed=\(claimed.map { "\($0.0)x\($0.1)" } ?? "none")"
                    )
                }
                // A window on screen with no claim can never render the grid
                // tmux assigns it — report it rather than skipping it.
                if onScreen, claimed == nil {
                    mismatches.append("on screen but never claimed a size")
                }
                guard onScreen else {
                    // Hidden mirrors stop tracking by design (their surfaces
                    // report collapsed sizes), so their grids are not judgeable —
                    // but a contradiction found above still reports.
                    if !mismatches.isEmpty {
                        windows.append([
                            "window": windowId,
                            "claimed": claimed.map { "\($0.0)x\($0.1)" } ?? "none",
                            "settled": false,
                            "mismatches": mismatches,
                        ])
                    }
                    continue
                }
                // While zoomed, the visible tree is what panes render.
                let tree = mirror.visibleLayout ?? mirror.layout
                let leavesByPaneID = tree.leavesByPaneID
                let metrics = mirror.nativeLayoutMetrics()
                let plannedOuterSizes: [Int: CGSize] = {
                    // Judge against the plan the renderer actually imposed:
                    // the sizing pass stashes its outer sizes, and re-planning
                    // here at the raw container would disagree with the
                    // render path (which plans at the exact-fit render frame)
                    // by the region's sub-cell remainder — a false unsettled
                    // verdict whenever that remainder exceeds the tolerance.
                    if !mirror.lastPlannedOuterSizes.isEmpty {
                        return mirror.lastPlannedOuterSizes
                    }
                    guard let metrics else { return [:] }
                    let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
                    let plan = planner.plan(
                        tree: RemoteTmuxNativeMeasuredSplitTree(
                            tree: RemoteTmuxNativeSplitTree(layout: tree),
                            metrics: metrics
                        ),
                        parentSize: mirror.renderFrameSize ?? mirror.containerSizePt
                    )
                    return planner.outerSizes(of: plan)
                }()
                var nativeGeometryReady = !plannedOuterSizes.isEmpty
                // A grid shortfall (or a pane with no sample yet) must keep the
                // window UNSETTLED on its own — the re-arm budget (below) is
                // capped, so once it stops the shortfall would otherwise be
                // listed in `mismatches` while `settled` flips true. Judge grids
                // live-first, matching the shortfall read below.
                var gridParityReady = true
                for leaf in tree.paneIDsInOrder {
                    guard let node = leavesByPaneID[leaf] else { continue }
                    if let planned = plannedOuterSizes[leaf],
                       let metrics,
                       let hostedView = mirror.panelsByPaneId[leaf]?.hostedView {
                        let actual = hostedView.frame.size
                        let plannedContent = CGSize(
                            width: planned.width,
                            height: max(0, planned.height - metrics.tabBarHeight)
                        )
                        if abs(plannedContent.width - actual.width) > 1.5
                            || abs(plannedContent.height - actual.height) > 1.5 {
                            nativeGeometryReady = false
                            // The portal positions this view from whichever pane HOST
                            // holds the surface's lease; a view at the wrong size with a
                            // correct plan usually means the lease is held by the wrong
                            // pane. Name both sides so the mismatch says which.
                            let lease = mirror.panelsByPaneId[leaf]?.surface.debugPortalHostLease()
                            let leasePane = lease?.paneId.map { String($0.uuidString.prefix(5)) } ?? "none"
                            let expectedPane = mirror.paneIdByPaneId[leaf].map {
                                String($0.id.uuidString.prefix(5))
                            } ?? "none"
                            let planText = "\(Int(plannedContent.width))x\(Int(plannedContent.height))"
                            let viewText = "\(Int(actual.width))x\(Int(actual.height))"
                            let leaseInWin = lease?.inWindow == true ? 1 : 0
                            var line = "%\(leaf) native-geometry plan=\(planText) view=\(viewText)"
                            line += " lease_pane=\(leasePane) expected_pane=\(expectedPane)"
                            line += " lease_inWin=\(leaseInWin)"
                            mismatches.append(line)
                        }
                    } else {
                        nativeGeometryReady = false
                    }
                    // Only a SHORTFALL is a defect: a pane one
                    // column under its span wraps every full line,
                    // while surplus is blank margin (the trailing
                    // pane legitimately absorbs sub-cell leftover).
                    // Judge the surface's LIVE grid, not the cached
                    // sample ledger: applied-resize reports can lag or
                    // miss a pin's resize, and a stale cache entry here
                    // failed a pane whose actual surface held exactly
                    // its assignment. The cache stays as the fallback
                    // for a surface with no live report yet.
                    let liveGrid = mirror.panelsByPaneId[leaf]?.surface.rawSizingSample()
                        .map { (cols: $0.columns, rows: $0.rows) }
                    guard let rendered = liveGrid ?? mirror.lastRenderedGrids[leaf] else {
                        // No size report yet: absence of evidence is
                        // not settled evidence — keep pollers waiting.
                        gridParityReady = false
                        mismatches.append(
                            "%\(leaf) no-sample assigned=\(node.width)x\(node.height)"
                        )
                        continue
                    }
                    // Surplus is deliberately NOT flagged here: a
                    // pane sharing an axis with a chrome-heavier
                    // sibling stack legitimately inherits several
                    // cells of blank fill margin, so grid surplus
                    // with a correctly placed view is not a defect.
                    // Overdraw is a VIEW property, and the anchor
                    // misplacement entries above already judge it
                    // exactly.
                    if rendered.cols < node.width || rendered.rows < node.height {
                        gridParityReady = false
                        var detail = "%\(leaf) rendered=\(rendered.cols)x\(rendered.rows)"
                            + " assigned=\(node.width)x\(node.height)"
                        // The surface's own pixel report — ground
                        // truth for diagnosing which side (plan or
                        // layout) lost the width.
                        if let sample = mirror.panelsByPaneId[leaf]?.surface.rawSizingSample() {
                            detail += " surfacePx=\(Int(sample.surfaceWidthPx))x\(Int(sample.surfaceHeightPx))"
                                + " cellPx=\(sample.cellWidthPx)x\(sample.cellHeightPx)"
                        }
                        // Layer bisect for a live mismatch: what the
                        // plan wants for this pane right now, and
                        // what its view actually measures. The plan
                        // size is the pane's OUTER box — it charges
                        // the per-pane tab bar — while view= is the
                        // terminal content below that bar, so a
                        // healthy pane reads exactly tab-bar-height
                        // shorter here. A WIDTH gap is the real
                        // signal: the split tree diverged from the
                        // plan, or the surface lags its view.
                        if let outer = plannedOuterSizes[leaf] {
                            detail += " planOuter=\(Int(outer.width))x\(Int(outer.height))"
                        }
                        if let view = mirror.panelsByPaneId[leaf]?.hostedView {
                            detail += " view=\(Int(view.frame.width))x\(Int(view.frame.height))"
                                + " inWin=\(view.window != nil ? 1 : 0)"
                        }
                        mismatches.append(detail)
                    }
                }
                // Geometry the grids cannot see: hosted terminal
                // views whose frame drifted off their anchor draw
                // OVER chrome (tab strips, dividers, neighbors)
                // even when every grid is exact.
                let mirrorHostedViewIDs = Set(
                    mirror.panelsByPaneId.values.map { ObjectIdentifier($0.hostedView) }
                )
                var portalGeometryReady = true
                if let hostWindow = mirror.visibleHostingContext()?.window {
                    let portalMismatches = TerminalWindowPortalRegistry
                        .misplacedHostedViewDescriptions(
                            for: hostWindow,
                            hostedViewIDs: mirrorHostedViewIDs
                        )
                    portalGeometryReady = portalMismatches.isEmpty
                    for desc in portalMismatches {
                        mismatches.append("misplaced \(desc)")
                    }
                }
                let windowGrid = session.connection.windowsByID[windowId]
                let publicationReady = !session.connection.hasPendingSizingSettlementWork(
                    windowId: windowId
                )
                let sizingReady = !mirror.sizingPassScheduled
                    && mirror.lastCompletedSizingInputs != nil
                    && nativeGeometryReady
                    && portalGeometryReady
                    && gridParityReady
                // Derivation parity. Delivery parity — claim == tmux layout —
                // cannot see a claim that tmux honored but that no longer matches
                // what the CURRENT container derives: the class where a stale
                // claim settles green while the region cannot render the columns
                // it promised. A window on screen must be able to re-derive its
                // own claim.
                //
                // Keyed off `onScreen`, an independent read of view state, and not
                // off `isVisibleForSizing`: that flag is the thing under test, and
                // a judge that consults it hands the defect a way to excuse itself.
                // A mirror that is off screen holds its attach-time claim by
                // design and has nothing to re-derive.
                let derivable: (columns: Int, rows: Int)? = {
                    guard let container = mirror.containerSizePt else { return nil }
                    return mirror.clientGrid(contentSize: container)
                }()
                // Absence of evidence is not settledness. An on-screen mirror with
                // no container, or one whose grid will not derive, cannot have
                // re-derived anything — and every other term can sit true on a
                // cached plan, so defaulting this one to true let exactly that
                // window settle green. Off screen, there is nothing to prove.
                let derivationSettled: Bool = {
                    guard onScreen else { return true }
                    guard let grid = derivable, let claimed else { return false }
                    return claimed.0 == grid.columns && claimed.1 == grid.rows
                }()
                let renderFrameDescription = Self.sizeDescription(mirror.renderFrameSize)
                let containerDescription = Self.sizeDescription(mirror.containerSizePt)
                windows.append([
                    "window": windowId,
                    "claimed": claimed.map { "\($0.0)x\($0.1)" } ?? "none",
                    "layout": "\(mirror.layout.width)x\(mirror.layout.height)",
                    "derivable": derivable.map { "\($0.columns)x\($0.rows)" } ?? "none",
                    // The terms `settled` is made of. Without them an unsettled
                    // window whose claim, derivable and layout all agreed with zero
                    // mismatches gave no clue which one was false.
                    "why": [
                        "connected": connected,
                        "publication_ready": publicationReady,
                        "sizing_ready": sizingReady,
                        "pass_scheduled": mirror.sizingPassScheduled,
                        "completed_inputs": mirror.lastCompletedSizingInputs != nil,
                        "native_geometry_ready": nativeGeometryReady,
                        "portal_geometry_ready": portalGeometryReady,
                        "grid_parity_ready": gridParityReady,
                        "derivation_settled": derivationSettled,
                        "window_grid": windowGrid.map { "\($0.width)x\($0.height)" } ?? "none",
                        "visible_for_sizing": mirror.isVisibleForSizing,
                        "on_screen": onScreen,
                        // The parent this judge plans from, beside the live one. A
                        // native-geometry mismatch says the panes disagree with a
                        // plan, and the plan is only as good as its parent: if the
                        // banked render frame has drifted from the container the
                        // views were laid out against, the disagreement is the
                        // judge's rather than the app's. Only reporting both tells
                        // those apart. Built above, not inline: this literal is
                        // already at the type-checker's limit.
                        "render_frame": renderFrameDescription,
                        "container": containerDescription,
                        // Does bonsplit's own LOGICAL tree agree with the tmux
                        // layout this plan was built from? Panes are portal-hosted
                        // at the window level, so a pane's frame tracks an anchor
                        // inside the split tree rather than the split tree itself:
                        // when the logical tree agrees and the geometry is still
                        // wrong, the stale thing is downstream of the tree, and the
                        // reconcile that consults this same predicate had no reason
                        // to rebuild. Without it, "the trees disagree" stays a
                        // guess, and it is the guess this judge kept inviting.
                        "tree_matches_layout": mirror.bonsplitTreeMatches(layout: tree),
                    ],
                    // The claim is a CLIENT size; `windowGrid` is the WINDOW tmux
                    // laid out. Columns agree exactly (tmux fits the window to the
                    // client width; dividers come out of panes, not the total), so
                    // a column disagreement is a real unlanded claim and stays in
                    // the gate. Rows do NOT: tmux spends rows on chrome (status
                    // line, pane-border title), and with an odd row remainder it
                    // hands the leftover to one stacked pane or the other from its
                    // own prior state (window 38 vs 39 for one stable claim of 39)
                    // — not a function of what we sent. So rows can't be asserted
                    // client==window; we settle on the panes rendering their
                    // assigned grids (gridParity, inside sizingReady) and the claim
                    // re-deriving from the current container (derivationSettled).
                    // A mismatch must DECIDE this, not merely accompany it.
                    // `settled` used to ignore `mismatches` entirely, so the
                    // "on screen but not visible-for-sizing" report below was loud
                    // in the payload and silent in the verdict: an on-screen mirror
                    // whose flag read false — the exact defect this judge exists to
                    // catch — settled GREEN, because `derivable` guards on that same
                    // flag, returns nil, and `?? true` then forces
                    // derivationSettled. The report has to be able to fail
                    // something or it is decoration.
                    "settled": claimed.map { claim in
                        guard let windowGrid else { return false }
                        guard mismatches.isEmpty else { return false }
                        return connected && publicationReady && sizingReady
                            && derivationSettled
                            && claim.0 == windowGrid.width
                    } ?? false,
                    "mismatches": mismatches,
                ])
            }
        }
        return [
            "connected": connectionsConnected,
            "windows": windows,
            // Monotonic work counters for the geometry-only regression
            // guard: a window MOVE (origin-only setFrame, titlebar drag)
            // must not run sizing passes, parity re-arms, or full portal
            // hierarchy syncs. The UI suite snapshots these, moves the
            // window repeatedly, and asserts zero deltas.
            "counters": [
                "sizing_pass": RemoteTmuxSizingDiagnostics.sizingPassCount,
                "parity_rearm": RemoteTmuxSizingDiagnostics.parityRearmCount,
                "full_hierarchy_sync": RemoteTmuxSizingDiagnostics.fullHierarchySyncCount,
            ],
        ]
    }

    /// `WxH` in whole points, or `none`.
    ///
    /// Shared so the same size never reads `none` in one field and `nil` in
    /// another for the same absent value. Named rather than inlined because the
    /// payload literal below is already at the type-checker's limit: a handful of
    /// inline `map { … } ?? "none"` closures in it push the whole expression past
    /// the budget, and one concrete call each type-checks instantly.
    nonisolated static func sizeDescription(_ size: CGSize?) -> String {
        guard let size else { return "none" }
        return "\(Int(size.width))x\(Int(size.height))"
    }
}
#endif
