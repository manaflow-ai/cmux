public import AppKit
public import Foundation
internal import CmuxCEFShim

/// One chrome-style CEF browser hosted in its own frameless NSWindow.
///
/// The window is created and owned by CEF; the host adopts it as a child
/// window over the pane rect. Navigation state arrives through `events`;
/// DevTools protocol traffic flows through `devToolsMessages` and
/// `sendDevToolsMessage`.
@MainActor
public final class CEFBrowser {
    /// Navigation and lifecycle signals, delivered on the main actor.
    public enum Event: Sendable {
        /// The browser exists; its NSWindow is available via `nsWindow`.
        case created
        /// The page title changed.
        case titleChanged(String)
        /// The main-frame address changed.
        case addressChanged(String)
        /// Loading state or history availability changed.
        case loadingStateChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
        /// The browser closed; the instance is inert afterwards.
        case closed
        /// The renderer process terminated unexpectedly.
        case rendererCrashed
    }

    /// The CEF-owned window hosting this browser, once `created` has fired.
    public private(set) var nsWindow: NSWindow?

    /// Whether the underlying browser has closed.
    public private(set) var isClosed = false

    private var handle: OpaquePointer?
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var devToolsContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var closeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var selfRetain: Unmanaged<CEFBrowser>?
    private var shouldBlockNavigation: ((URL) -> Bool)?

    deinit {
        for task in closeTimeoutTasks.values { task.cancel() }
    }

    /// Creates a browser and its hosting window.
    ///
    /// - Parameters:
    ///   - url: Initial navigation target.
    ///   - cachePath: Profile storage directory below CEF's root cache path,
    ///     or `nil` for the shared global context.
    /// - Returns: The browser, or `nil` when CEF is unavailable.
    public static func create(
        url: URL,
        cachePath: String?,
        shouldBlockNavigation: ((URL) -> Bool)? = nil
    ) -> CEFBrowser? {
        guard CEFRuntime.isInitialized else { return nil }
        let browser = CEFBrowser()
        browser.shouldBlockNavigation = shouldBlockNavigation
        let context = Unmanaged.passRetained(browser)
        browser.selfRetain = context

        var callbacks = cmux_cef_browser_callbacks_t()
        callbacks.context = context.toOpaque()
        callbacks.on_created = { context, nsWindow in
            let browser = unmanagedBrowser(context)
            let window: NSWindow?
            if let nsWindow {
                window = Unmanaged<NSWindow>.fromOpaque(nsWindow).takeUnretainedValue()
            } else {
                window = nil
            }
            MainActor.assumeIsolated {
                browser.handleCreated(window: window)
            }
        }
        callbacks.on_closed = { context in
            let browser = unmanagedBrowser(context)
            MainActor.assumeIsolated {
                browser.handleClosed()
            }
        }
        callbacks.on_renderer_crashed = { context in
            let browser = unmanagedBrowser(context)
            MainActor.assumeIsolated {
                browser.publish(.rendererCrashed)
            }
        }
        callbacks.should_block_navigation = { context, rawURL in
            let browser = unmanagedBrowser(context)
            guard let rawURL,
                  let url = URL(string: String(cString: rawURL)) else { return 1 }
            return MainActor.assumeIsolated {
                browser.shouldBlockNavigation?(url) == true ? 1 : 0
            }
        }
        callbacks.on_title_changed = { context, title in
            let browser = unmanagedBrowser(context)
            let value = title.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                browser.publish(.titleChanged(value))
            }
        }
        callbacks.on_address_changed = { context, url in
            let browser = unmanagedBrowser(context)
            let value = url.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                browser.publish(.addressChanged(value))
            }
        }
        callbacks.on_loading_state_changed = { context, isLoading, canGoBack, canGoForward in
            let browser = unmanagedBrowser(context)
            MainActor.assumeIsolated {
                browser.publish(.loadingStateChanged(
                    isLoading: isLoading != 0,
                    canGoBack: canGoBack != 0,
                    canGoForward: canGoForward != 0
                ))
            }
        }
        callbacks.on_dev_tools_message = { context, bytes, length in
            let browser = unmanagedBrowser(context)
            guard let bytes, length > 0 else { return }
            let data = Data(bytes: bytes, count: length)
            MainActor.assumeIsolated {
                browser.publishDevToolsMessage(data)
            }
        }

        let handle = url.absoluteString.withCString { urlString in
            withOptionalCString(cachePath) { cachePathString in
                withUnsafePointer(to: callbacks) { pointer in
                    cmux_cef_browser_create(urlString, cachePathString, pointer)
                }
            }
        }
        guard let handle else {
            context.release()
            browser.selfRetain = nil
            return nil
        }
        browser.handle = handle
        return browser
    }

    private init() {}

    /// Streams navigation and lifecycle events until the browser closes.
    ///
    /// CEF delivers window and browser creation synchronously during
    /// `create`, so a subscriber attaching afterwards replays `.created`
    /// immediately instead of waiting for an event that already happened.
    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            if isClosed {
                continuation.finish()
                return
            }
            eventContinuations[id] = continuation
            if nsWindow != nil {
                continuation.yield(.created)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Streams complete DevTools protocol messages (results and events).
    public func devToolsMessages() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            if isClosed {
                continuation.finish()
                return
            }
            devToolsContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.devToolsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Navigates the main frame.
    public func load(url: URL) {
        guard let handle else { return }
        url.absoluteString.withCString { cmux_cef_browser_load_url(handle, $0) }
    }

    /// Whether the browser currently has an older session-history entry.
    public var canGoBack: Bool {
        guard let handle else { return false }
        return cmux_cef_browser_can_go_back(handle) != 0
    }

    /// Traverses one entry back in session history.
    public func goBack() {
        if let handle { cmux_cef_browser_go_back(handle) }
    }

    /// Whether the browser currently has a newer session-history entry.
    public var canGoForward: Bool {
        guard let handle else { return false }
        return cmux_cef_browser_can_go_forward(handle) != 0
    }

    /// Traverses one entry forward in session history.
    public func goForward() {
        if let handle { cmux_cef_browser_go_forward(handle) }
    }

    /// Reloads the current page.
    public func reload() {
        if let handle { cmux_cef_browser_reload(handle) }
    }

    /// Cancels the active load.
    public func stopLoading() {
        if let handle { cmux_cef_browser_stop(handle) }
    }

    /// Requests asynchronous teardown; `.closed` fires when complete.
    public func close() {
        if let handle { cmux_cef_browser_close(handle) }
    }

    /// Requests teardown and waits until CEF has released the browser window.
    ///
    /// This is the safe lifecycle boundary for policy or workspace changes:
    /// callers must not expose a replacement request context before `.closed`.
    public func closeAndWait(timeout: Duration = .seconds(15)) async -> Bool {
        guard !isClosed else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if isClosed {
                    continuation.resume(returning: true)
                    return
                }
                closeWaiters[waiterID] = continuation
                closeTimeoutTasks[waiterID] = Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.finishCloseWaiter(
                        waiterID,
                        closed: false,
                        requestClose: true
                    )
                }
                close()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.finishCloseWaiter(waiterID, closed: false)
            }
        })
    }

    /// Submits one DevTools protocol command.
    ///
    /// - Parameter message: UTF-8 JSON with `id`, `method`, optional `params`.
    /// - Returns: `true` when the command was accepted for delivery.
    @discardableResult
    public func sendDevToolsMessage(_ message: Data) -> Bool {
        guard let handle, !isClosed else { return false }
        return message.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return cmux_cef_browser_send_dev_tools_message(handle, base, buffer.count) != 0
        }
    }

    // MARK: - Callback handling

    private func handleCreated(window: NSWindow?) {
        nsWindow = window
        publish(.created)
    }

    private func handleClosed() {
        isClosed = true
        nsWindow = nil
        publish(.closed)
        let waiters = Array(closeWaiters.values)
        closeWaiters.removeAll()
        for task in closeTimeoutTasks.values { task.cancel() }
        closeTimeoutTasks.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
        for continuation in devToolsContinuations.values { continuation.finish() }
        devToolsContinuations.removeAll()
        if let handle {
            cmux_cef_browser_release(handle)
            self.handle = nil
        }
        // Balance the retain taken at creation; the shim no longer calls back.
        selfRetain?.release()
        selfRetain = nil
    }

    @discardableResult
    private func finishCloseWaiter(
        _ waiterID: UUID,
        closed: Bool,
        requestClose: Bool = false
    ) -> Bool {
        guard let waiter = closeWaiters.removeValue(forKey: waiterID) else { return false }
        closeTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        if requestClose { close() }
        waiter.resume(returning: closed)
        return true
    }

    private func publish(_ event: Event) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func publishDevToolsMessage(_ data: Data) {
        for continuation in devToolsContinuations.values { continuation.yield(data) }
    }
}

@MainActor
private func unmanagedBrowser(_ context: UnsafeMutableRawPointer?) -> CEFBrowser {
    Unmanaged<CEFBrowser>.fromOpaque(context!).takeUnretainedValue()
}

private func withOptionalCString<R>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
