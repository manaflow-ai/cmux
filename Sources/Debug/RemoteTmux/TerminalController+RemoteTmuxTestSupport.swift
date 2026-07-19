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
            return args.count == 5 && args[1] == "-t" && isAtom(args[2])
                && args[3] == "-x" && isDimension(args[4])
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

    /// `remote.tmux.test_set_frame` (DEBUG only) — resizes a cmux window to an
    /// exact size from within the app.
    ///
    /// Exists for the sizing UI tests: driving window sizes with XCUITest
    /// mouse drags depends on the desktop around the app (an overlapping
    /// window from any other application invokes XCUITest's permission-dialog
    /// interruption scan, which crashes on elements whose accessibility value
    /// is numeric). `NSWindow.setFrame` drives the same resize path the
    /// window server does, deterministically. Never compiled into release.
    nonisolated func v2RemoteTmuxTestSetFrame(id: Any?, params: [String: Any]) -> String {
        guard let idString = params["window_id"] as? String,
              let windowId = UUID(uuidString: idString),
              let width = params["width"] as? Double, width > 100,
              let height = params["height"] as? Double, height > 100
        else {
            return v2Error(id: id, code: "invalid_params", message: "window_id, width, height are required")
        }
        // Generous timeout: the hop onto the main actor can wait out a busy
        // render/output burst in a test app running a dozen live panes.
        return v2VmCall(id: id, timeoutSeconds: 30) {
            // Read back the frame AFTER setFrame: AppKit clamps to min/max
            // content sizes and screen bounds, so the actual size is the only
            // trustworthy answer — callers assert on it rather than assuming
            // the request applied.
            let applied: CGSize? = await MainActor.run {
                guard let window = AppDelegate.shared?.windowForMainWindowId(windowId) else {
                    return nil
                }
                var frame = window.frame
                // Keep the top-left corner anchored so the window stays on screen.
                frame.origin.y += frame.size.height - height
                frame.size = CGSize(width: width, height: height)
                window.setFrame(frame, display: true, animate: false)
                return window.frame.size
            }
            guard let applied else {
                throw RemoteTmuxError.unreachable("window not found: \(idString)")
            }
            return [
                "applied_width": Double(applied.width),
                "applied_height": Double(applied.height),
            ]
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
            for (windowId, mirror) in session.windowMirrorByWindowId {
                // A window tmux no longer lists cannot settle and
                // must not be judged; its mirror is mid-teardown.
                guard liveWindowIds.contains(windowId) else { continue }
                // Hidden mirrors stop tracking by design (they claim
                // once and their surfaces report collapsed sizes);
                // only the visible mirror's state is judgeable.
                guard mirror.isEffectivelyVisibleForSizing else { continue }
                let claimed = mirror.connection?.lastWindowSizes[windowId]
                var mismatches: [String] = []
                // While zoomed, the visible tree is what panes render.
                let tree = mirror.visibleLayout ?? mirror.layout
                let leavesByPaneID = tree.leavesByPaneID
                let metrics = mirror.nativeLayoutMetrics()
                let plannedOuterSizes: [Int: CGSize] = {
                    guard let metrics else { return [:] }
                    let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
                    let plan = planner.plan(
                        tree: RemoteTmuxNativeMeasuredSplitTree(
                            tree: RemoteTmuxNativeSplitTree(layout: tree),
                            metrics: metrics
                        ),
                        parentSize: mirror.containerSizePt
                    )
                    return planner.outerSizes(of: plan)
                }()
                var nativeGeometryReady = !plannedOuterSizes.isEmpty
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
                            mismatches.append(
                                "%\(leaf) native-geometry"
                                    + " plan=\(Int(plannedContent.width))x\(Int(plannedContent.height))"
                                    + " view=\(Int(actual.width))x\(Int(actual.height))"
                            )
                        }
                    } else {
                        nativeGeometryReady = false
                    }
                    // Only a SHORTFALL is a defect: a pane one
                    // column under its span wraps every full line,
                    // while surplus is blank margin (the trailing
                    // pane legitimately absorbs sub-cell leftover).
                    guard let rendered = mirror.lastRenderedGrids[leaf] else {
                        // No size report yet: absence of evidence is
                        // not settled evidence — keep pollers waiting.
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
                        // what its view actually measures. plan≠view
                        // means the split tree diverged from the
                        // plan; plan==view but surface short means
                        // the portal-hosted surface lags its view.
                        if let outer = plannedOuterSizes[leaf] {
                            detail += " plan=\(Int(outer.width))x\(Int(outer.height))"
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
                windows.append([
                    "window": windowId,
                    "claimed": claimed.map { "\($0.0)x\($0.1)" } ?? "none",
                    "layout": "\(mirror.layout.width)x\(mirror.layout.height)",
                    "settled": claimed.map {
                        guard let windowGrid else { return false }
                        return connected && publicationReady && sizingReady
                            && $0.0 == windowGrid.width && $0.1 == windowGrid.height
                    } ?? false,
                    "mismatches": mismatches,
                ])
            }
        }
        return ["connected": connectionsConnected, "windows": windows]
    }
}
#endif
