import Darwin

/// The process's signal actions around `CefInitialize`. Chromium resets every
/// signal action when it starts (and installs its own SIGINT, SIGHUP and
/// SIGTERM quit handlers), which would silently remove the app's crash
/// reporter and quit handling. The runtime captures them right before
/// `CefInitialize` and puts them back right after, whether it succeeded or
/// not, so starting Chromium changes nothing about how cmux handles signals.
struct CEFSignalActions {
    /// Every catchable signal (SIGKILL and SIGSTOP cannot be caught).
    static let signals: [Int32] = (Int32(1)..<Int32(NSIG)).filter { $0 != SIGKILL && $0 != SIGSTOP }

    private var saved: [(Int32, sigaction)] = []

    static func capture() -> CEFSignalActions {
        var actions = CEFSignalActions()
        for signal in signals {
            var action = sigaction()
            if sigaction(signal, nil, &action) == 0 { actions.saved.append((signal, action)) }
        }
        return actions
    }

    func restore() {
        for (signal, action) in saved {
            var action = action
            _ = sigaction(signal, &action, nil)
        }
    }

    var count: Int { saved.count }
}
