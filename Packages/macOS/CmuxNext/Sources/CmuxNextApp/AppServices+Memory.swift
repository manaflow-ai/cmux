// The app's memory consumer registrations (plans/cmux-next/chrome-parity/p07-memory.md, task 077).
//
// Chrome registers each memory consumer where it is built (base/memory_coordinator/memory_consumer.h:
// the consumer owns its RAII `MemoryConsumerRegistration`). cmux's composition root is AppServices, so
// the wiring of every package's consumers lives in this one file and AppServices.swift calls
// `registerMemoryConsumers()` once. Each package adds one line or one small function here, kept in
// package name order, so parallel changes add lines and do not edit the same ones. It is its own type,
// not an AppServices extension, so these lines never grow the AppServices god type.

import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextPages
import CmuxNextTerminal
import CmuxNextWakeups

/// Runs the memory coordinator's release slices on a budgeted frame queue: on a later frame, after input
/// and visible work, never in the turn that asks (Chrome posts memory release as BEST_EFFORT tasks).
private final class FrameReleaseSlicer: MemoryReleaseSlicer {
    /// The background-class queue the slices run on.
    let queue: FrameBatchQueue

    init(queue: FrameBatchQueue) {
        self.queue = queue
    }

    func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {
        queue.enqueue(slice)
    }
}

/// Registers every package's memory consumers with the app's memory coordinator.
struct AppMemoryConsumers {
    /// The services whose subsystems own the consumers.
    let services: AppServices

    /// The app's one memory coordinator: it follows `pressure` and releases in background-class frame
    /// work on `mainWork`. AppServices holds it next to its pressure source.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - mainWork: The app's main-thread scheduler.
    /// - Returns: The coordinator.
    static func coordinator(pressure: MemoryPressureEvents, mainWork: MainWorkScheduler) -> MemoryCoordinator {
        MemoryCoordinator(pressure: pressure, slicer: FrameReleaseSlicer(
            queue: FrameBatchQueue(owner: "MemoryCoordinator.release", budgeted: .background, on: mainWork)))
    }

    /// AppServices' init calls this once, after the services the consumers belong to are built. Each
    /// consumer's owner keeps its registration token; nothing here stores one.
    func registerMemoryConsumers() {
        _ = services.memoryCoordinator  // follows pressure from launch, before any consumer registers
        // One line per package, sorted by package name, for example:
        // registerTabs()  // CmuxNextTabs
        registerInternalPageDiscards()  // CmuxNextApp
        registerPageLifecycle()  // CmuxNextPages
        registerTerminalLastFrames()  // CmuxNextTerminal
    }

    /// `memoryTerminalLastFrames` (default off): evicted terminals' last frames are one lossless
    /// consumer that drops them all at critical and reports their volatile bytes apart (p07-memory-035).
    private func registerTerminalLastFrames() {
        guard services.features.isEnabled(.memoryTerminalLastFrames) else { return }
        services.cache.lastFrames.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `pageLifecycle` (default off): page tabs' reveal and conceal drive the page lifecycle
    /// (p13-webui-022), on the app's one deadline scheduler. Agent chats join in p13-webui-038.
    private func registerPageLifecycle() {
        guard services.features.isEnabled(.pageLifecycle) else { return }
        installPageLifecycle(PageLifecycle(deadlines: services.mainDeadlines))
    }

    /// Makes `lifecycle` the one lifecycle of cmux pages: a page tab's reveal and conceal drive it, a
    /// page WebUIHost closes leaves it, and the browser hibernation (`startHibernation`) hands it
    /// `browser.hibernation`, the memory pressure and Low Power Mode. Tests pass one on their own deadlines.
    func installPageLifecycle(_ lifecycle: PageLifecycle) {
        let pages = services.pages
        lifecycle.pageOfTab = { [weak pages] key in (pages?.existingView(key)?.content as? PageWebView).map(PageWebViewLifecycle.init) }
        services.webUI.lifecycle = lifecycle
        services.cache.pageLifecycle = lifecycle
    }

    /// `memoryDiscardInternalPages` (default off): hidden page tabs' views go after their policy. With
    /// `pageLifecycle` on, that lifecycle is page tabs' one discard controller, so this one stays off.
    private func registerInternalPageDiscards() {
        guard services.features.isEnabled(.memoryDiscardInternalPages), !services.features.isEnabled(.pageLifecycle) else { return }
        services.pages.enableDiscards(ContentDiscardScheduler(kind: .internalPage, memory: services.memoryCoordinator), on: services.cache)
    }
}
