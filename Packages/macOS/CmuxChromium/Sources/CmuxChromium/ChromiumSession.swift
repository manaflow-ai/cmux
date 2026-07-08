public import Foundation
import os

/// One live Chromium browser: a Content Shell process plus its Mojo connection.
///
/// Created by ``ChromiumRuntime/openSession(initialURL:userDataDirectory:proxyServer:)``.
/// Observe ``events`` (single consumer) for compositor, navigation, and
/// lifecycle changes; ``ChromiumWebView`` does this when it hosts a session.
public final class ChromiumSession: Sendable {
    /// The wire values of `OwlFreshDevToolsMode`.
    public enum DevToolsMode: UInt32, Sendable {
        /// Docked below the page.
        case bottom = 0
        /// Docked to the right of the page.
        case right = 1
        /// Docked to the left of the page.
        case left = 2
        /// A separate DevTools window.
        case window = 3
    }

    /// Events from the browser process. Single-consumer; iterate from one task only.
    public let events: AsyncStream<ChromiumSessionEvent>

    private let executor: ChromiumRuntimeExecutor
    private let handle: OwlSessionHandle
    private let sink: OwlEventSink
    // Lock carve-out: one-shot close guard checked synchronously from deinit and close().
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(
        executor: ChromiumRuntimeExecutor,
        handle: OwlSessionHandle,
        sink: OwlEventSink,
        events: AsyncStream<ChromiumSessionEvent>
    ) {
        self.executor = executor
        self.handle = handle
        self.sink = sink
        self.events = events
    }

    deinit {
        close()
    }

    /// Destroys the browser process. Idempotent; later calls are no-ops.
    public func close() {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        let handle = handle
        let sink = sink
        executor.post { library in
            library.sessionDestroy(handle.raw)
            // Balances the passRetained made when the session was created; no
            // callback can fire after sessionDestroy returns.
            Unmanaged.passUnretained(sink).release()
        }
        sink.continuation.finish()
    }

    /// Loads a URL in the session's web view.
    public func navigate(to url: String) async throws {
        try await withSession { library, session in
            var error: UnsafeMutablePointer<CChar>?
            let status = url.withCString { library.navigate(session, $0, &error) }
            try library.throwIfFailed(status, error)
        }
    }

    /// Resizes the web view. Fire-and-forget; safe to call from layout passes.
    ///
    /// - Parameters:
    ///   - width: Content width in points.
    ///   - height: Content height in points.
    ///   - scale: Backing scale factor of the hosting window.
    public func resize(width: Int, height: Int, scale: CGFloat) {
        guard width > 0, height > 0 else { return }
        let handle = handle
        executor.post { library in
            var error: UnsafeMutablePointer<CChar>?
            _ = library.resize(handle.raw, UInt32(width), UInt32(height), Float(scale), &error)
            _ = library.takeString(error)
        }
    }

    /// Tells the renderer whether the web view has keyboard focus. Fire-and-forget.
    public func setFocus(_ focused: Bool) {
        let handle = handle
        executor.post { library in
            var error: UnsafeMutablePointer<CChar>?
            _ = library.setFocus(handle.raw, focused, &error)
            _ = library.takeString(error)
        }
    }

    /// Forwards a mouse or scroll event. Fire-and-forget.
    public func send(_ event: ChromiumMouseEvent) {
        let handle = handle
        executor.post { library in
            var error: UnsafeMutablePointer<CChar>?
            _ = library.sendMouse(
                handle.raw,
                event.kind.rawValue,
                event.x, event.y,
                event.button.rawValue,
                event.clickCount,
                event.deltaX, event.deltaY,
                event.modifiers,
                &error
            )
            _ = library.takeString(error)
        }
    }

    /// Forwards a keyboard event. Fire-and-forget.
    public func send(_ event: ChromiumKeyEvent) {
        let handle = handle
        executor.post { library in
            var error: UnsafeMutablePointer<CChar>?
            let status = event.text.withCString {
                library.sendKey(handle.raw, event.isKeyDown, event.keyCode, $0, event.modifiers, &error)
            }
            _ = status
            _ = library.takeString(error)
        }
    }

    /// Runs JavaScript in the shell's first window and returns the JSON-encoded result.
    public func executeJavaScript(_ script: String) async throws -> String {
        try await withSession { library, session in
            var result: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = script.withCString { library.shellExecuteJavaScript(session, $0, &result, &error) }
            try library.throwIfFailed(status, error)
            return library.takeString(result) ?? ""
        }
    }

    /// Opens DevTools docked per `mode`.
    public func openDevTools(mode: DevToolsMode = .bottom) async throws {
        try await withSession { library, session in
            var ok = false
            var error: UnsafeMutablePointer<CChar>?
            let status = library.devToolsOpen(session, mode.rawValue, &ok, &error)
            try library.throwIfFailed(status, error)
        }
    }

    /// Closes DevTools if open.
    public func closeDevTools() async throws {
        try await withSession { library, session in
            var ok = false
            var error: UnsafeMutablePointer<CChar>?
            let status = library.devToolsClose(session, &ok, &error)
            try library.throwIfFailed(status, error)
        }
    }

    /// Captures the current page as JSON (`png` is base64-encoded pixels).
    public func captureSurfaceJSON() async throws -> String {
        try await withSession { library, session in
            var result: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = library.captureSurfaceJSON(session, &result, &error)
            try library.throwIfFailed(status, error)
            return library.takeString(result) ?? ""
        }
    }

    private func withSession<T: Sendable>(
        _ body: @escaping @Sendable (OwlRuntimeLibrary, OpaquePointer) throws -> T
    ) async throws -> T {
        guard !closed.withLock({ $0 }) else {
            throw ChromiumRuntimeError.sessionClosed
        }
        let handle = handle
        return try await executor.run { library in
            try body(library, handle.raw)
        }
    }
}
