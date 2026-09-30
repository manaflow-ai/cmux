import AppKit
import CmuxNextControl

/// Entry point called from the Xcode target's `App/main.swift`.
public enum CmuxNextApp {
    public static func main() {
        // Before any socket or pipe exists: a write to a closed peer returns
        // EPIPE instead of ending the process (Chrome and most macOS network
        // apps do the same; CEF sets it anyway once Chromium starts). Every
        // write site already handles the error, and sockets also set
        // SO_NOSIGPIPE. Children get the default back: Foundation's Process
        // and Chromium reset it, and the one forkpty site resets it itself.
        _ = signal(SIGPIPE, SIG_IGN)
        // Before any thread starts or anything reads the environment: drop
        // cmux variables inherited from a shell inside another cmux, so they
        // cannot pick this app's socket, tag, or daemon session.
        LaunchIdentity.stripInheritedEnvironment()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
