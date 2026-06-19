import AppKit
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("WindowCoordinator owns only window identity and the close broadcast")
struct WindowCoordinatorTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    @Test("register adds the id and binds the window handle both ways")
    func registerBindsIdentity() {
        let coordinator = WindowCoordinator()
        let window = makeWindow()
        let id = WindowID(UUID())

        coordinator.register(window, id: id)

        #expect(coordinator.windowIds == [id])
        #expect(coordinator.window(for: id) === window)
        #expect(coordinator.id(for: window) == id)
    }

    @Test("re-registering an id rebinds it to the new window")
    func reRegisterRebinds() {
        let coordinator = WindowCoordinator()
        let id = WindowID(UUID())
        let first = makeWindow()
        let second = makeWindow()

        coordinator.register(first, id: id)
        coordinator.register(second, id: id)

        #expect(coordinator.windowIds == [id])
        #expect(coordinator.window(for: id) === second)
        #expect(coordinator.id(for: first) == nil)
    }

    @Test("explicit unregister drops the id and returns its window without emitting closed")
    func explicitUnregisterIsSilent() async {
        let coordinator = WindowCoordinator()
        let window = makeWindow()
        let id = WindowID(UUID())
        coordinator.register(window, id: id)

        let removed = coordinator.unregister(id)

        #expect(removed === window)
        #expect(coordinator.windowIds.isEmpty)
        #expect(coordinator.window(for: id) == nil)
    }

    @Test("closing a registered window yields its id on the closed stream exactly once and drops it from the live set")
    func closeBroadcastsOnce() async {
        let coordinator = WindowCoordinator()
        let window = makeWindow()
        let id = WindowID(UUID())
        coordinator.register(window, id: id)

        var iterator = coordinator.windowClosed.makeAsyncIterator()

        // The selector-based observer fires synchronously on the posting thread
        // (main), matching the app's WindowCloseObserver.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        let closedId = await iterator.next()
        #expect(closedId == id)
        // Dropped from the live identity set immediately...
        #expect(coordinator.windowIds.isEmpty)
        // ...but the closing window stays resolvable until the deferred consumer
        // calls `unregister`, so teardown that runs one turn later can read it.
        #expect(coordinator.window(for: id) === window)

        let removed = coordinator.unregister(id)
        #expect(removed === window)
        #expect(coordinator.window(for: id) == nil)
    }

    @Test("the closing window survives a deferred turn with no remaining external strong ref")
    func closingWindowSurvivesDeferredTurnWithoutExternalStrongRef() async {
        // Reproduces the real teardown path: a `CmuxMainWindow` uses the stock
        // `isReleasedWhenClosed = true` and its only strong owner is dropped
        // synchronously during `willClose`. Here the test holds the sole strong
        // ref and releases it before the deferred turn, so only the coordinator's
        // close-pin keeps the window alive. Without the pin, `window(for:)` would
        // be nil on the deferred turn and the app's `unregisterMainWindow` would
        // be skipped entirely (the silent-drop the refuters flagged).
        let coordinator = WindowCoordinator()
        let id = WindowID(UUID())
        weak var weakWindow: NSWindow?

        func registerAndClose() {
            let window = makeWindow()
            window.isReleasedWhenClosed = false  // keep ARC, not AppKit, in control for the test
            weakWindow = window
            coordinator.register(window, id: id)
            // Synchronous willClose, mirroring the app: this pins the window in
            // the coordinator and yields the id.
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            // `window` local goes out of scope here, dropping the last external
            // strong ref.
        }
        registerAndClose()

        // Drain the broadcast on a later turn, exactly like the app consumer.
        var iterator = coordinator.windowClosed.makeAsyncIterator()
        let closedId = await iterator.next()
        #expect(closedId == id)

        // The coordinator's pin is the only strong ref now; resolution must
        // still succeed so teardown is not dropped.
        #expect(weakWindow != nil)
        #expect(coordinator.window(for: id) === weakWindow)

        // Releasing the pin lets the window deallocate.
        _ = coordinator.unregister(id)
        #expect(coordinator.window(for: id) == nil)
    }

    @Test("closing an unrelated window does not broadcast the registered id")
    func unrelatedCloseIsIgnored() {
        let coordinator = WindowCoordinator()
        let registered = makeWindow()
        let other = makeWindow()
        let id = WindowID(UUID())
        coordinator.register(registered, id: id)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)

        #expect(coordinator.windowIds == [id])
    }
}
