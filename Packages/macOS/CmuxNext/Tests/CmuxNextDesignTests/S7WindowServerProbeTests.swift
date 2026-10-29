import AppKit
import CoreGraphics
import Darwin
import Foundation
import Testing

/// A diagnostic, not a test to land (branch cp/fix-tip-swift-s7-ui-probe): why a window the fleet's test process
/// orders front never reaches the window server's on-screen list. Prints the process's launch context (launchd
/// domain, bootstrap session, parent chain, audit session), the screen lock and display sleep, the activation
/// policy and whether changing it puts the window on screen. Every line starts with "S7WS".
@MainActor @Suite(.serialized)
struct S7WindowServerProbeTests {
    private func say(_ line: String) { print("S7WS \(line)") }

    private func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "error: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func onScreen(_ window: NSWindow) -> Bool {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    @Test func launchContext() {
        let pid = getpid(), uid = getuid()
        say("pid=\(pid) uid=\(uid) euid=\(geteuid()) user=\(NSUserName()) consoleUser=\(shell("/usr/bin/stat", ["-f", "%Su", "/dev/console"]))")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        for key in session.keys.sorted() { say("cgsession \(key)=\(session[key] ?? "")") }
        say("environment XPC_SERVICE_NAME=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "-") __CFBundleIdentifier=\(ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "-") SSH_CONNECTION=\(ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil) LaunchInstanceID=\(ProcessInfo.processInfo.environment["LaunchInstanceID"] ?? "-")")
        // The process's launchd domain and bootstrap: a GUI app's is gui/<uid>, Aqua session type.
        say("launchctl procinfo:\n" + shell("/bin/launchctl", ["procinfo", "\(pid)"]).split(separator: "\n")
            .filter { $0.contains("domain") || $0.contains("session") || $0.contains("bootstrap") || $0.contains("spawn type")
                || $0.contains("responsible") || $0.contains("program") || $0.contains("Aqua") }
            .prefix(25).joined(separator: "\nS7WS   "))
        say("launchctl managername=\(shell("/bin/launchctl", ["managername"])) manageruid=\(shell("/bin/launchctl", ["manageruid"]))")
        say("launchctl print gui/\(uid) head:\n" + shell("/bin/launchctl", ["print", "gui/\(uid)"]).split(separator: "\n").prefix(8)
            .joined(separator: "\nS7WS   "))
        // The parent chain up to launchd: who started the test process.
        var chain: [String] = []
        var current = pid
        for _ in 0..<12 {
            let line = shell("/bin/ps", ["-o", "ppid=,user=,comm=", "-p", "\(current)"])
            chain.append("\(current): \(line)")
            guard let parent = Int32(line.split(separator: " ").first ?? ""), parent > 1 else { break }
            current = parent
        }
        say("parent chain:\nS7WS   " + chain.joined(separator: "\nS7WS   "))
        say("audit session: \(shell("/usr/bin/id", ["-a"]))")
    }

    @Test func screenAndDisplay() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        say("screenIsLocked=\(session["CGSSessionScreenIsLocked"] ?? "absent") screenSaver=\(shell("/bin/ps", ["-axo", "comm"]).contains("ScreenSaverEngine"))")
        say("displays active=\(activeDisplays()) online=\(onlineDisplays()) mainAsleep=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0) mainActive=\(CGDisplayIsActive(CGMainDisplayID()) != 0) mainOnline=\(CGDisplayIsOnline(CGMainDisplayID()) != 0)")
        say("pmset assertions/display: " + shell("/usr/bin/pmset", ["-g"]).split(separator: "\n").filter { $0.contains("displaysleep") || $0.contains("sleep ") }.joined(separator: " | "))
        say("ioreg display power: " + shell("/usr/sbin/ioreg", ["-n", "IODisplayWrangler", "-r", "-d", "1"]).split(separator: "\n")
            .filter { $0.contains("CurrentPowerState") || $0.contains("DevicePowerState") }.joined(separator: " | "))
        say("frontmost app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") menuBarOwner=\(NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier ?? "nil")")
        let loginWindow = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .map { "\($0[kCGWindowOwnerName as String] ?? "?")@\($0[kCGWindowLayer as String] ?? "?")" }
        say("on-screen windows (\(loginWindow.count)): \(loginWindow.prefix(30).joined(separator: ", "))")
    }

    private func activeDisplays() -> UInt32 { var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); return n }
    private func onlineDisplays() -> UInt32 { var n: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &n); return n }

    /// Does an NSAnimationContext group on a window that has a screen but is not on screen ever call its
    /// completion? QuickComposerPanel's fold (and Motion.animateTimed) wait on it.
    @Test func anAnimationGroupOnAnOffScreenWindowCompletes() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        spin(0.3)
        let started = Date()
        var done: Date?
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            window.animator().setFrame(CGRect(x: 200, y: 200, width: 300, height: 44), display: true)
        }, completionHandler: { done = Date() })
        spin(3)
        say("animation group: screen=\(window.screen != nil) onScreen=\(onScreen(window)) completedAfter=\(done.map { String(format: "%.2f s", $0.timeIntervalSince(started)) } ?? "never (3 s)") frameHeight=\(window.frame.height)")
    }

    @Test func activationPolicyAndWindow() {
        let app = NSApplication.shared
        say("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath) LSUIElement=\(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") ?? "-") LSBackgroundOnly=\(Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") ?? "-")")
        say("start policy=\(app.activationPolicy().rawValue) active=\(app.isActive) running=\(app.isRunning)")
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        spin(0.5)
        say("prohibited/as-is: onScreen=\(onScreen(window)) occlusionVisible=\(window.occlusionState.contains(.visible))")
        for (name, policy) in [("accessory", NSApplication.ActivationPolicy.accessory), ("regular", .regular)] {
            let changed = app.setActivationPolicy(policy)
            app.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            spin(1.0)
            say("\(name): set=\(changed) policy=\(app.activationPolicy().rawValue) active=\(app.isActive) onScreen=\(onScreen(window)) key=\(window.isKeyWindow) occlusionVisible=\(window.occlusionState.contains(.visible))")
        }
        let level = NSWindow(contentRect: CGRect(x: 600, y: 200, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        level.isReleasedWhenClosed = false
        defer { level.orderOut(nil) }
        level.level = .screenSaver
        level.orderFrontRegardless()
        spin(0.5)
        say("screenSaver-level borderless: onScreen=\(onScreen(level))")
    }
}
