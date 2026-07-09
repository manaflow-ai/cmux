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
import Foundation
import os

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
        guard let tmpdir = (params["tmpdir"] as? String),
              tmpdir.hasPrefix("/tmp/"), !tmpdir.contains("..")
        else {
            return v2Error(id: id, code: "invalid_params", message: "tmpdir must be under /tmp")
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
        // Only known tmux install paths: in allowAll socket mode this verb is
        // reachable by any local user, so it must not be a generic exec.
        let allowedBins: Set<String> = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let bin = (params["bin"] as? String) ?? "/opt/homebrew/bin/tmux"
        guard allowedBins.contains(bin) else {
            return v2Error(id: id, code: "invalid_params", message: "bin must be a known tmux path")
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            try? FileManager.default.createDirectory(atPath: tmpdir, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["TMUX_TMPDIR"] = tmpdir
            env.removeValue(forKey: "TMUX")
            proc.environment = env
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            // Drain BOTH pipes on GCD readability handlers and require both
            // EOFs before finalizing: every append happens on the handler
            // queue before its EOF signal, so no chunk can race the join.
            let drained = DispatchGroup()
            let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
            let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
            for (handle, buffer) in [
                (out.fileHandleForReading, stdoutBuffer),
                (err.fileHandleForReading, stderrBuffer),
            ] {
                drained.enter()
                handle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        drained.leave()
                    } else {
                        buffer.withLock { $0.append(chunk) }
                    }
                }
            }
            // This closure runs as an async Task on the cooperative pool, so
            // it must suspend — never park — while the subprocess runs: exit
            // arrives via terminationHandler (installed before run() so a
            // fast exit cannot be missed) and the EOF join via the group's
            // notify, in place of waitUntilExit()/wait().
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                proc.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                drained.notify(queue: .global()) { continuation.resume() }
            }
            let stdout = stdoutBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
            let stderr = stderrBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
            return [
                "exit": Int(status),
                "stdout": stdout,
                "stderr": stderr,
            ]
        }
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
}
#endif
