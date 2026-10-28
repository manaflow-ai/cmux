import Foundation

/// Who decides a key before a DevTools frontend sees it (task 033 of
/// plans/cmux-next/chrome-parity/p01-process.md, the DevTools half of task 030).
///
/// The DevTools actions (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C) win over the frontend. Chrome decides them in its
/// browser process before the DevTools renderer sees the key (chrome/browser/devtools/devtools_window.cc,
/// `DevToolsWindow::PreHandleKeyboardEvent` hands it to the inspected browser window's accelerators).
nonisolated enum CEFDevToolsKeyPolicy: Equatable, Sendable {
    /// In process: Chromium's DevTools client asks cmux in its pre-key hook (`cefDevToolsKeyCallback`)
    /// for a key that reached Chromium without passing `CmuxApplication.sendEvent`.
    case preKeyHook
    /// Host mode: no host window is ever key, so every key passes cmux's `sendEvent`, where the key router
    /// runs the DevTools actions before a key goes on the wire. The host's DevTools client asks no one:
    /// cmux installs no handler, and the remote shim's DevTools key policy is NULL.
    case embedderFirst

    init(hostMode: Bool) {
        self = hostMode ? .embedderFirst : .preKeyHook
    }
}

extension CEFRuntime {
    /// Who decides DevTools keys for this runtime: the Chromium Host (``hostStart``) never asks cmux.
    var devToolsKeyPolicy: CEFDevToolsKeyPolicy { CEFDevToolsKeyPolicy(hostMode: hostStart != nil) }

    /// Installs the DevTools key handler ``devToolsKeyPolicy`` asks for: `cefDevToolsKeyCallback` in
    /// process, NULL in host mode, where no key waits on cmux.
    func installDevToolsKeyPolicy() {
        guard let shim else { return }
        // SAFETY: the handler is a C function of the shim's key_fn type (or NULL); the shim calls it with the
        // context it was initialized with, the runtime, which lives for the process once started.
        unsafe shim.devToolsSetKeyHandler(devToolsKeyPolicy == .preKeyHook ? cefDevToolsKeyCallback : nil)
    }
}
