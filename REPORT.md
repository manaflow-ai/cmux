# Swift 6 Concurrency Audit — cmux

Exhaustive scan of the cmux app (Swift 5 language mode), CLI, and SPM packages for concurrency patterns with a strictly better Swift 6 / modern-concurrency solution. Criteria from the `swift-guidance` skill (concurrency, actor-isolation, nonisolated/@concurrent).

**Total findings: 334** — {'high': 83, 'medium': 241, 'critical': 10} by severity; {'semaphore-block': 26, 'unchecked-sendable-race': 20, 'dispatch-main': 70, 'async-after-timing': 74, 'manual-lock': 51, 'unstructured-task': 46, 'combine': 24, 'completion-handler': 20, 'sendable-mainactor': 3} by category.

**In scope for this PR's fixes: 41** findings across 23 self-contained files (high confidence, low/medium ripple, critical/high severity).

**Deferred** (catalogued, not fixed here): the large god-files (`TerminalController.swift`, `Workspace.swift`, `TabManager.swift`, `ContentView.swift`, `BrowserPanel.swift`, `GhosttyTerminalView.swift`, `cmuxApp.swift`, `AppDelegate.swift`, `CLI/cmux.swift`) and any high-ripple/low-confidence items. Reasons: typing-latency-critical paths fenced off in CLAUDE.md, API-rippling async conversions (e.g. CLI websocket `receiveSync`/`waitForSocket` would make every caller async), and single-PR verifiability. These are real follow-ups, not noise.

Fixes are organized per source file (one bug bundle per file) so independent fixes in the same file don't conflict. See `findings/` for the per-bundle docs fed to the fix workflow.

---

## In-scope files

### `Sources/Find/SurfaceSearchOverlay.swift` (5 in scope / 5 total)

#### **[IN SCOPE]** `Sources/Find/SurfaceSearchOverlay.swift:258-262` — DispatchQueue.main.async for state mutation in Coordinator (focusField)
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** Inside focusField(), a DispatchQueue.main.async is used to defer state mutation (self.lastSelectedRange). The Coordinator is a reference type holding UI state. Deferring mutations to the next runloop via DispatchQueue.main.async is error-prone: it introduces timing races, makes the code harder to reason about, and violates the goal of making mutations explicit and synchronous where possible. Since Coordinator is already bound to AppKit's main thread (it's a delegate), this work should execute inline or use async/await structured concurrency if a wait is genuinely needed.
- **Swift 6 solution:** Use @MainActor on the Coordinator class to make it main-actor-bound. Then perform state mutations directly without DispatchQueue.main.async. If async deferral is needed (e.g., waiting for another operation), use Task or async/await with a real wait point, not an empty dispatch.
- **Fix:** Mark 'final class Coordinator: NSObject, NSTextFieldDelegate' as '@MainActor final class Coordinator'. Remove the DispatchQueue.main.async at line 258–262 and perform the mutation inline: 'self.lastSelectedRange = selection' directly in focusField(). If you need to defer for AppKit-internal reasons (e.g., waiting for a layout pass), use Task { @MainActor in ... } or investigate whether the deferral is necessary at all.

#### **[IN SCOPE]** `Sources/Find/SurfaceSearchOverlay.swift:278-280` — DispatchQueue.main.async for binding mutation in controlTextDidBeginEditing
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** controlTextDidBeginEditing() uses DispatchQueue.main.async { self.parent.isFocused = true } to update a binding. This defers the mutation to the next event loop, creating a one-frame lag and a race condition: the binding update is not immediately visible, and concurrent mutations can sneak in. For a main-actor bound object, mutations should be direct and immediate.
- **Swift 6 solution:** Perform the binding update directly inline, or if AppKit's delegate callback contract requires deferral, use Task { @MainActor in ... } with an explicit (and minimal) async point that documents why deferral is needed.
- **Fix:** Remove the DispatchQueue.main.async block and write 'self.parent.isFocused = true' directly at line 279. If AppKit's delegate lifecycle requires the update to happen after the callback returns, wrap in 'Task { @MainActor in self.parent.isFocused = true }'.

#### **[IN SCOPE]** `Sources/Find/SurfaceSearchOverlay.swift:292-294` — DispatchQueue.main.async for binding mutation in controlTextDidEndEditing
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** controlTextDidEndEditing() uses DispatchQueue.main.async { self.parent.isFocused = false } for the same reason as line 278. Same race/lag issue.
- **Swift 6 solution:** Same as line 278: use direct assignment or Task { @MainActor in ... } if AppKit requires post-callback deferral.
- **Fix:** Remove the DispatchQueue.main.async and assign 'self.parent.isFocused = false' directly, or wrap in Task { @MainActor in ... } if the callback contract requires it.

#### **[IN SCOPE]** `Sources/Find/SurfaceSearchOverlay.swift:310-313` — DispatchQueue.main.async for state mutation in control(_:textView:doCommandBy:)
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** Inside the control(_:textView:doCommandBy:) delegate callback, a DispatchQueue.main.async is used to defer rememberSelection(from:). This introduces a race window where the selection is not immediately captured. The correct pattern is to capture selection synchronously in the callback, then defer UI updates if needed—not defer the capture itself.
- **Swift 6 solution:** Move the selection capture outside the async block (or inline). If internal state writes must be deferred, structure them with Task { @MainActor in ... }, but capturing data from the current event should be synchronous.
- **Fix:** Reorder: call 'self?.rememberSelection(from: textView)' directly (without DispatchQueue.main.async wrapping). Only if rememberSelection() must run later (unlikely), wrap it in Task { @MainActor in ... }, but capture the NSTextView data now, before the callback returns.

#### **[IN SCOPE]** `Sources/Find/SurfaceSearchOverlay.swift:429-438` — DispatchQueue.main.async for state mutation in updateNSView
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** Inside updateNSView() (a SwiftUI representable update callback), DispatchQueue.main.async { coordinator?.pendingFocusRequest = nil; ... } is used to apply focus changes. This defers the focus restoration to the next runloop, causing a one-frame flicker. Focus should be applied synchronously within the representable lifecycle if possible, or via Task { @MainActor in ... } if an async wait is genuinely needed.
- **Swift 6 solution:** Use structured concurrency with @MainActor task lifecycle instead of DispatchQueue.main.async. If the focus must happen after updateNSView() returns (AppKit constraint), use Task { @MainActor in ... } and document why.
- **Fix:** Replace DispatchQueue.main.async block with inline assignment 'coordinator?.pendingFocusRequest = nil' followed by the focus logic, or if AppKit timing requires post-return execution, wrap in 'Task { @MainActor in ... }'. Consider whether the focusField() call can happen synchronously within the representable lifecycle instead.

### `Sources/CmuxConfig.swift` (3 in scope / 6 total)

#### [deferred] `Sources/CmuxConfig.swift:2-2` — Remove Combine import, migrate to async/await
- category: `combine` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/CmuxConfig.swift:1949-1955` — Replace NotificationCenter.publisher with async Notification.notifications stream
- category: `combine` · severity: **high** · ripple: low · confidence: high
- **Problem:** Combine publisher + .receive(on: DispatchQueue.main) + .sink is clunky for a trivial reactive update. The class is @MainActor, so the explicit main dispatch is redundant. This also ties the config store's lifetime to explicit cancellable storage, making it fragile if the Set is cleared without warning.
- **Swift 6 solution:** Use `Task { for await _ in Notification.notifications(named: CmuxActionTrust.didChangeNotification) { self.loadAll() } }` or a simpler async observation pattern. Async/await naturally composes with @MainActor and avoids framework overhead.
- **Fix:** Create an async init helper or move the observer setup to a separate async method called from init. The observer should acquire/release with the store's lifecycle. Store the Task handle if needed to cancel on deinit, but for a simple listen-until-dead pattern, the Task can leak naturally.

#### [deferred] `Sources/CmuxConfig.swift:1995-2000` — Replace tabManager tracking Combine publisher with async observation
- category: `combine` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/CmuxConfig.swift:3071-3071` — Convert @escaping () -> Void completion handler to async closure on watchQueue
- category: `completion-handler` · severity: **medium** · ripple: medium · confidence: medium

#### **[IN SCOPE]** `Sources/CmuxConfig.swift:3105-3119` — Replace asyncAfter retry loop with async Task and proper state tracking
- category: `async-after-timing` · severity: **high** · ripple: low · confidence: high
- **Problem:** scheduleLocalReattach uses DispatchQueue.asyncAfter with a 0.5s delay to retry file watcher attachment after deletion. This is a timing hack (repo CLAUDE.md bans sleep-based timing in runtime code) and makes the retry logic fragile. If the file reappears quickly, the delay may miss it. If it takes longer than 0.5s, the attempt counter advances without progress. The recursion through attempts also couples retry policy to the call stack.
- **Swift 6 solution:** Use an async Task with Task.sleep(for:) instead of asyncAfter. Track retry state explicitly in a local variable or state machine, polling the file system with proper backoff via exponential delay or a FileWatcher-like AsyncSequence. Better: use Darwin file events directly through an async wrapper rather than timing-based polling.
- **Fix:** Refactor scheduleLocalReattach into an async method that runs a loop: check file exists, if not attempt up to N times with Task.sleep(nanoseconds:) between checks. Call this from the event handler wrapped in Task { @MainActor in … } so it runs on main but doesn't block the dispatch source queue. This removes the timing brittleness and makes retry intent explicit.

#### **[IN SCOPE]** `Sources/CmuxConfig.swift:3175-3191` — Replace asyncAfter retry loop in global file watcher with async Task polling
- category: `async-after-timing` · severity: **high** · ripple: low · confidence: high
- **Problem:** scheduleGlobalReattach uses watchQueue.asyncAfter for file watcher reattachment retry, identical timing-hack problem as scheduleLocalReattach (line 3105). The 0.5s fixed delay is brittle, and recursive attempt tracking through the call stack is fragile.
- **Swift 6 solution:** Use an async Task with Task.sleep instead of asyncAfter. Implement proper retry backoff with explicit state. Reuse the refactored async pattern from scheduleLocalReattach so both retry loops share the same robust logic.
- **Fix:** Convert to async Task loop with explicit retry count tracking and Task.sleep(nanoseconds:) between polls. Call from DispatchSource event handler via Task { @MainActor in await self.reattachGlobalWatcher(attempt: 1) }. This removes timing fragility and makes intent clear.

### `Sources/Feed/FeedCoordinator.swift` (3 in scope / 12 total)

#### [deferred] `Sources/Feed/FeedCoordinator.swift:15-27` — FeedCoordinator: @unchecked Sendable with mutable state not fully protected
- category: `unchecked-sendable-race` · severity: **high** · ripple: high · confidence: medium

#### **[IN SCOPE]** `Sources/Feed/FeedCoordinator.swift:26-27` — NSLock protecting waiters dict should be an actor
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Manual NSLock with lock/unlock calls around waiters dictionary access is error-prone and verbose. An actor with isolated mutable state is the modern Swift Concurrency primitive that replaces manual locks. Race condition risk if any access path forgets to lock (code review tax).
- **Swift 6 solution:** actor-isolated mutable state instead of NSLock
- **Fix:** Create an actor WaiterRegistry { var waiters: [String: PendingWaiter]; func register(...), lookup(...), remove(...) } or inline into an actor FeedCoordinator. Replace all waiterLock.lock/unlock pairs with async method calls. Removes 6 lock/unlock sites (lines 105-107, 135-137, 157-162, 182-186, etc.).

#### [deferred] `Sources/Feed/FeedCoordinator.swift:100-133` — DispatchSemaphore blocks socket worker thread on blocking hook reply
- category: `semaphore-block` · severity: **critical** · ripple: high · confidence: high

#### **[IN SCOPE]** `Sources/Feed/FeedCoordinator.swift:114-114` — DispatchQueue.main.sync blocks socket worker on main-actor mutation
- category: `dispatch-main` · severity: **high** · ripple: medium · confidence: high
- **Problem:** DispatchQueue.main.sync inside ingestBlocking() blocks the socket thread waiting for the main actor to execute the store mutation. If the main thread is busy, this creates a deadlock: socket thread waits on main, main thread may be processing other socket commands. Even without deadlock, blocking the socket thread on every blocking hook degrades responsiveness.
- **Swift 6 solution:** @MainActor async mutation with Task / DispatchQueue.main.async instead of .sync
- **Fix:** Defer the itemIdSlot capture to the reply handler. Instead of synchronously reading itemIdSlot after the sync block, create an async bridge: post the event with DispatchQueue.main.async, capture the returned itemId in a Continuation or continuation parameter, resume when the store responds. Removes the blocking wait entirely.

#### **[IN SCOPE]** `Sources/Feed/FeedCoordinator.swift:218-218` — DispatchQueue.main.sync blocks on main-actor expiry in expireTimedOutItem
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** expireTimedOutItem() uses DispatchQueue.main.sync from the socket worker thread to expire items on timeout. Blocking the socket thread on main-actor work degrades socket responsiveness. The check for Thread.isMainThread attempts to avoid deadlock but is fragile if called from a main-actor context already.
- **Swift 6 solution:** DispatchQueue.main.async instead of .sync
- **Fix:** Replace DispatchQueue.main.sync with DispatchQueue.main.async. Remove the Thread.isMainThread check (the async path is always safe). Socket worker posts the expiry asynchronously and continues. Called from ingestBlocking after semaphore timeout, so the function itself can remain sync if needed.

#### [deferred] `Sources/Feed/FeedCoordinator.swift:229-235` — PendingWaiter: @unchecked Sendable with mutable decision field
- category: `unchecked-sendable-race` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Feed/FeedCoordinator.swift:240-242` — UnsafeItemIdSlot: @unchecked Sendable wrapping mutable value
- category: `unchecked-sendable-race` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Feed/FeedCoordinator.swift:244-246` — SnapshotSlot: @unchecked Sendable wrapping mutable array
- category: `unchecked-sendable-race` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Feed/FeedCoordinator.swift:273-273` — DispatchQueue.main.sync blocks socket thread on snapshot read
- category: `dispatch-main` · severity: **medium** · ripple: medium · confidence: high

#### [deferred] `Sources/Feed/FeedCoordinator.swift:417-417` — postNotificationIfStillAwaiting launches fire-and-forget Task without handle
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Feed/FeedCoordinator.swift:583-583` — deliverFeedNotificationIfStillAwaiting launches nested fire-and-forget Task
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Feed/FeedCoordinator.swift:640-640` — addNotificationIfStillAwaiting launches nested fire-and-forget Task in center.add callback
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: medium

### `Sources/Panels/FilePreviewPanel.swift` (3 in scope / 6 total)

#### [deferred] `Sources/Panels/FilePreviewPanel.swift:4-4` — Remove unused Combine import; migrate ObservableObject to @Observable
- category: `combine` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/Panels/FilePreviewPanel.swift:441-503` — Convert NSLock-protected dictionary to actor in FilePreviewDragRegistry
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** FilePreviewDragRegistry uses NSLock to guard mutable state (pending dictionary). While the lock discipline is correct (lock/unlock pairs, defer guards), the pattern is verbose, manual, and error-prone. Every method must remember lock/defer, and any new method adds risk of a forgotten unlock. More importantly, this is exactly what actors are designed for: exclusive access to mutable state with compile-time isolation checking.
- **Swift 6 solution:** Convert FilePreviewDragRegistry to an actor. Move pending into actor-isolated storage, make methods isolated by default, and remove all manual lock/unlock/defer calls. The actor model guarantees exclusive access and cancellation safety.
- **Fix:** Change 'final class FilePreviewDragRegistry' to 'actor FilePreviewDragRegistry', remove 'static let shared' and replace with a nonisolated static let that initializes it once (using a private initializer or a static async var if needed). Move all methods into the actor body; most become async automatically. Call sites that currently say 'lock.lock()' disappear—the actor ensures atomicity. Update all call sites to await. Ripple: moderate, because callers in FilePreviewDragPasteboardWriter (lines 559-564) must become async, and any synchronous call paths must be refactored. Check grep results for all uses of shared.register/consume/etc.

#### [deferred] `Sources/Panels/FilePreviewPanel.swift:629-634` — Use @MainActor isolation instead of DispatchQueue.main.async in drag pasteboard writer
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Panels/FilePreviewPanel.swift:1398-1404` — Replace DispatchQueue.asyncAfter with Task-based timer in SwiftUI animation loop
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/Panels/FilePreviewPanel.swift:2534-2540` — Replace nested DispatchQueue.async calls with async/await in PDF document loading
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** PDF document loading uses DispatchQueue to chain off-main I/O (documentLoadQueue.async) with main-thread result handling (DispatchQueue.main.async). This creates a hard-to-follow pyramid of closures, weak captures, and manual null-checks (guard let self, self.currentURL == loadURL). If loading is cancelled (URL changes), the pending main dispatch still runs, requiring ad-hoc generation/cancellation tokens. Task-based structured concurrency replaces all of this with a single async/await flow and automatic cancellation on scope exit.
- **Swift 6 solution:** Use Task { @MainActor in } with await FilePreviewKindResolver.resolveMode() / await FilePreviewTextLoader.load(), plus proper task handles stored in @State for cancellation. Alternatively, if this is a property or heavy computation, wrap in a Task that checks isCancelled / generation tokens as safeguards.
- **Fix:** Replace setURL's documentLoadQueue.async + nested DispatchQueue.main.async with: Task { [weak self, loadURL] in let document = PDFDocument(url: loadURL); guard !Task.isCancelled else { return }; await MainActor.run { guard let self, self.currentURL == loadURL else { return }; self.applyLoadedPDFDocument(document, for: loadURL) } }. Store the Task handle in a @State or property so it can be cancelled when a new URL is set. Ripple: low to moderate. The setURL caller doesn't change, but the method must now be async (or use unstructured Task, which is less clean).

#### **[IN SCOPE]** `Sources/Panels/FilePreviewPanel.swift:3744-3750` — Replace nested DispatchQueue.async calls with async/await in image loading
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** Same pattern as PDF loading (lines 2534–2540): off-main image I/O (imageLoadQueue.async) followed by main-thread result handling (DispatchQueue.main.async). Creates closure pyramids, weak captures, manual cancellation tracking (guard currentURL == loadURL), and lost opportunity for structured task cancellation.
- **Swift 6 solution:** Refactor to async/await with proper Task handle storage for cancellation.
- **Fix:** Replace imageLoadQueue.async + nested DispatchQueue.main.async with Task-based loading. Store the Task in a property so it cancels when setURL is called again. Similar structure to PDF fix above. Ripple: low.

### `Sources/SessionIndexStore.swift` (3 in scope / 4 total)

#### **[IN SCOPE]** `Sources/SessionIndexStore.swift:17-57` — SessionIndexRipgrepCancellation: manual lock protecting mutable state should be actor
- category: `unchecked-sendable-race` · severity: **high** · ripple: low · confidence: high
- **Problem:** Class uses @unchecked Sendable with manual NSLock to guard mutable pid state (activeProcessIdentifier, finishedProcessIdentifier) accessed from both Process.terminationHandler and Task cancellation contexts. The lock is correct, but the comment claims 'onCancel cannot await an actor' — this is incorrect. onCancel blocks can capture actor-isolated state or use nonisolated(unsafe) closures.
- **Swift 6 solution:** Convert to an isolated actor (not @unchecked Sendable) with async methods markStarted(), markFinished(), and cancel(). The actor will provide compile-time isolation and eliminate manual lock complexity.
- **Fix:** Change 'final class SessionIndexRipgrepCancellation: @unchecked Sendable' to 'final actor SessionIndexRipgrepCancellation' (remove @unchecked Sendable), remove NSLock(), convert methods to async (markStarted, markFinished, cancel remain sync only where needed — onCancel can still call synchronous paths via nonisolated helpers if truly needed). Low ripple risk: type is internal, only instantiated once per ripgrep call.

#### **[IN SCOPE]** `Sources/SessionIndexStore.swift:65-92` — ClaudeMetadataCache: manual lock should be actor
- category: `unchecked-sendable-race` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Global singleton cache uses @unchecked Sendable with NSLock() to protect dictionary (entries). Accessed concurrently from TaskGroup operations (line 1486, 1531) where isolation context is clear. Manual locks are fragile and provide no compile-time safety.
- **Swift 6 solution:** Convert ClaudeMetadataCache to an actor with async get(url:mtime:) -> SessionEntry? and async put(url:mtime:entry:) methods. Eliminate NSLock() and @unchecked Sendable. Actor isolation will be inherited by static var shared.
- **Fix:** Change 'final class ClaudeMetadataCache: @unchecked Sendable' to 'final actor ClaudeMetadataCache', remove NSLock, convert get() and put() to async. Call sites in TaskGroup use 'await cache.get(...)' and 'await cache.put(...)'. Medium ripple: ~2 call sites at lines 1486/1531 need await, but those are already in async contexts.

#### [deferred] `Sources/SessionIndexStore.swift:110-114` — SessionDragRegistry.register() uses Task.sleep() as timer-based auto-expiry
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: medium

#### **[IN SCOPE]** `Sources/SessionIndexStore.swift:1119-1130` — ErrorBag: manual lock should be actor
- category: `unchecked-sendable-race` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Thread-safe error accumulator uses @unchecked Sendable with NSLock() to protect messages array. Passed through concurrent TaskGroup operations. Manual lock is fragile and provides no compiler validation that all accesses are serialized.
- **Swift 6 solution:** Convert ErrorBag to an actor with async add(msg:) and async snapshot() methods. Actor isolation replaces lock, and type safety is enforced at compile time.
- **Fix:** Change 'final class ErrorBag: @unchecked Sendable' to 'final actor ErrorBag', remove NSLock, convert add() and snapshot() to async. Call sites like errorBag.add(...) become 'await errorBag.add(...)'. Low-medium ripple: ErrorBag is passed down through all agent loaders; callers are already async.

### `Sources/Update/UpdateTitlebarAccessory.swift` (3 in scope / 11 total)

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:3-3` — Replace Combine import with async/await for SwiftUI view updates
- category: `combine` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/Update/UpdateTitlebarAccessory.swift:233-236` — Replace DispatchQueue.main.async bridge with direct MainActor method
- category: `dispatch-main` · severity: **high** · ripple: medium · confidence: high
- **Problem:** NotificationsPopoverVisibilityState.setShown() manually dispatches to main queue when called off-main, but the method's state mutations (_Published @Published fields) require main-actor isolation anyway. The Thread.isMainThread check and async dispatch is unnecessary—this is a redundant main-thread bridge pattern that should use MainActor nonisolated(unsafe) or restructure the caller.
- **Swift 6 solution:** Mark setShown and setShownOnMain as @MainActor methods. Callers off-main should use async/await: `await someObserver.setShown(...)`. If synchronous calls from off-main are unavoidable, require the caller to dispatch explicitly, not the observer.
- **Fix:** Add @MainActor to setShown and setShownOnMain. Callers that hit the off-main case need to be evaluated for proper async/await structure. This is a surgical change but ripples to all call sites of setShown (line 226, 234).

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:774-780` — Redundant main dispatch in SwiftUI view body callback
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:1253-1260` — Redundant main dispatch in HiddenTitlebarSidebarControlsView WindowAccessor
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:1610-1622` — Fire-and-forget Task in notification observer should use explicit cancellation handle
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:1650-1659` — Fire-and-forget Task in appResignObserver without cancellation storage
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:1723-1723` — Use Timer or AsyncStream instead of DispatchQueue.asyncAfter for modifier key hint delay
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:2409-2420` — Unnecessary main dispatch in SwiftUI action closures that are already MainActor context
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/Update/UpdateTitlebarAccessory.swift:2835-2835` — Use Task.sleep instead of DispatchQueue.asyncAfter for startup window scan retry delay
- category: `async-after-timing` · severity: **critical** · ripple: medium · confidence: high
- **Problem:** TitlebarAccessoryViewController.attachIfNeeded() uses DispatchQueue.main.asyncAfter(deadline: .now() + delay) to retry attachment after a fixed delay. This is a timing hack that blocks on wall-clock duration rather than waiting for a real signal (window becoming key, WindowAccessor identifier being assigned, or a retry queue). The delay is non-deterministic under testing and in fast startup scenarios.
- **Swift 6 solution:** Replace with Task.sleep(nanoseconds:) inside a structured async context, or better: implement a retry queue with exponential backoff and real signals (window state changes, layout cycles) instead of fixed delays. SwiftUI's @Environment and WindowAccessor already signal when identifiers are assigned.
- **Fix:** Replace the asyncAfter chain (lines 2835, 2854-2857) with Task.sleep or a real condition. Refactor pendingAttachRetries into a structured retry handler that waits for observable signals (isMainTerminalWindow becoming true) instead of timing. This is a moderate refactor (~30 lines) that improves determinism.

#### **[IN SCOPE]** `Sources/Update/UpdateTitlebarAccessory.swift:2854-2857` — Nested asyncAfter with Task wrapper for retry backoff should use Task.sleep
- category: `async-after-timing` · severity: **high** · ripple: medium · confidence: high
- **Problem:** attachIfNeeded retry logic uses DispatchQueue.main.asyncAfter with a 0.05s delay, then spawns Task { @MainActor } inside the completion. This is a fragile double-dispatch pattern mixing DispatchQueue timing with structured concurrency. The pattern is hard to cancel and test.
- **Swift 6 solution:** Use Task.sleep(nanoseconds: 50_000_000) with structured cancellation, or implement a real condition-based retry (exponential backoff watching isMainTerminalWindow state) instead of fixed delays.
- **Fix:** Refactor the retry loop to store Task handles and use Task.sleep with proper cancellation. Or add a retry state machine that responds to window state changes via a notification or @Environment observer instead of timing.

#### [deferred] `Sources/Update/UpdateTitlebarAccessory.swift:2935-2941` — Unnecessary main dispatch for layout invalidation that should run on main
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

### `Sources/FileExplorerStore.swift` (2 in scope / 6 total)

#### **[IN SCOPE]** `Sources/FileExplorerStore.swift:314-387` — SSHFileExplorerProvider @unchecked Sendable with manual lock instead of actor
- category: `unchecked-sendable-race` · severity: **high** · ripple: medium · confidence: high
- **Problem:** SSHFileExplorerProvider is marked @unchecked Sendable and captures mutable state (`state: State` at line 324) that is protected by NSLock (lines 323, 327-329, 332-336, 380-387). This is lock-protected correctly but is fragile: lock contention on the main/UI thread (e.g., when `isAvailable` property is checked), deadlock risk if any lock holder calls back to the main thread or awaits async work while holding the lock, and the @unchecked annotation silences compiler safety checks that would catch future mutations.
- **Swift 6 solution:** Convert to an actor with isolated mutable properties. `final actor SSHFileExplorerProvider` with isolated `var state` would eliminate the lock, provide compiler-enforced isolation, and scale safely to concurrent callers without deadlock risk. Swift 6 actors are strictly better than manual locking for this pattern.
- **Fix:** Change `final class SSHFileExplorerProvider: FileExplorerProvider, @unchecked Sendable` to `final actor SSHFileExplorerProvider: FileExplorerProvider`. Remove `private let stateLock = NSLock()` and `private var state: State`. Replace with `nonisolated let connection`, `nonisolated let displayTarget`, `nonisolated let transport` (immutable), and `isolated var state: State`. Make `homePath` and `isAvailable` property getters `nonisolated` (Swift 6 allows reading isolated state from nonisolated sync getters if it never blocks). Call sites using `sshProvider.homePath` already read the property; they will continue to work as before since property access is still fast and non-blocking. The `updateAvailability` method becomes an isolated mutation, which is fine since it is called from the main thread context. `resolveHomePath()` and `listDirectory()` are already async and can safely await and mutate isolated state. rippleRisk is medium: actor properties change how the type is exposed, and any code that tries to mutate `state` directly will fail at compile time (good), but call sites that already use the public API (property getters, methods) need no changes.

#### **[IN SCOPE]** `Sources/FileExplorerStore.swift:435-508` — SSHCommandProcess @unchecked Sendable with manual lock protecting cancelled flag
- category: `unchecked-sendable-race` · severity: **high** · ripple: medium · confidence: high
- **Problem:** SSHCommandProcess is marked @unchecked Sendable and uses NSLock to protect the `cancelled` bool (line 441) that is mutated in `run()` (lines 451-453, 465-467, 481-483) and `terminate()` (lines 496-498). Although the lock correctly guards access, this is fragile: NSLock on the critical `cancelled` flag in a synchronous `run()` method that calls `process.waitUntilExit()` (line 479) creates a blocking wait on the calling thread (typically a background Dispatch queue at line 514). If `terminate()` is called from a different executor while `run()` holds the lock and waits, deadlock is possible. Additionally, the lock-protected state is opaque to the compiler, silencing safety checks.
- **Swift 6 solution:** Convert to an actor. `final actor SSHCommandProcess` with isolated `var cancelled: Bool` and `let process`, `let pipes`, `let gate` (immutable). Both `run()` and `terminate()` are naturally `isolated` methods. The `run()` method's `process.waitUntilExit()` call becomes non-blocking conceptually because the actor executor is uncontended. If strict synchronous semantics are required (e.g., returning `SSHCommandResult` synchronously), use `nonisolated(unsafe)` for the Process and Pipe fields, but keep the `cancelled` flag isolated and guarded by the actor; the compiler will warn when unsafe access is attempted.
- **Fix:** Change `private final class SSHCommandProcess: @unchecked Sendable` to `private final actor SSHCommandProcess`. Remove `private let lock = NSLock()` and replace all `lock.lock() ... lock.unlock()` pairs with simple reads/writes of isolated `cancelled`. The `run()` and `terminate()` methods remain largely unchanged in body, but locking calls vanish and the compiler enforces isolation. The return type `throws -> SSHCommandResult` stays the same; callers at line 515 (`continuation.resume(with: Result { try commandProcess.run() })`) will need to be updated to `await` the call: `continuation.resume(with: Result { try await commandProcess.run() })`. rippleRisk is medium because `run()` changes from sync to async, requiring the DispatchQueue.global async block at line 514–516 to await the method.

#### [deferred] `Sources/FileExplorerStore.swift:510-526` — Synchronous Process.run() wrapped in withCheckedThrowingContinuation blocks background queue
- category: `async-after-timing` · severity: **high** · ripple: low · confidence: medium

#### [deferred] `Sources/FileExplorerStore.swift:869-869` — DispatchQueue.main.asyncAfter used for prefetch debounce instead of Task timing
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/FileExplorerStore.swift:1125-1125` — FileExplorerDirectoryWatcher uses @escaping closure callback instead of AsyncStream or Combine
- category: `completion-handler` · severity: **medium** · ripple: medium · confidence: medium

#### [deferred] `Sources/FileExplorerStore.swift:1161-1170` — FileExplorerDirectoryWatcher uses DispatchQueue.asyncAfter for debounce instead of Task timing
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

### `Sources/Panels/CmuxWebView.swift` (2 in scope / 5 total)

#### **[IN SCOPE]** `Sources/Panels/CmuxWebView.swift:489-516` — Synchronous JavaScript evaluation blocks main thread with RunLoop polling
- category: `dispatch-main` · severity: **high** · ripple: medium · confidence: high
- **Problem:** evaluateJavaScriptSynchronously() pumps the RunLoop in a busy loop waiting for an async callback, freezing keyboard handling and UI during the timeout. This pattern blocks key-equivalent processing (the caller) on JavaScript evaluation that may take its full 0.25s timeout, during which user keypresses are stalled. The RunLoop.run() calls are an attempt to unblock nested callbacks, but the overall architecture is a synchronous-blocking anti-pattern on the main thread.
- **Swift 6 solution:** Replace with async/await via withCheckedContinuation, or thread the JavaScript evaluation result through an AsyncStream. Modern WKWebView APIs may support async evaluation; if not, use Task { @MainActor } with proper awaiting rather than RunLoop blocking.
- **Fix:** Convert evaluateJavaScriptSynchronously to an async function using withCheckedContinuation { continuation in evaluateJavaScript(...) { ... continuation.resume(...) } }. Update all call sites (pageCanAcceptPlainTextPaste) to be async and propagate the async requirement. This removes the main-thread blocking loop entirely and lets the system schedule other work while waiting.

#### [deferred] `Sources/Panels/CmuxWebView.swift:1537-1545` — Manual thread check with DispatchQueue.main.async fallback for callback
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Panels/CmuxWebView.swift:1690-1774` — Nested completion handlers for cookie fetch, network request, and save dialog
- category: `completion-handler` · severity: **high** · ripple: high · confidence: high

#### [deferred] `Sources/Panels/CmuxWebView.swift:1869-1891` — File I/O on global queue followed by DispatchQueue.main.async
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

#### **[IN SCOPE]** `Sources/Panels/CmuxWebView.swift:1903-1949` — Nested completion handlers for cookie fetch and network request
- category: `completion-handler` · severity: **high** · ripple: medium · confidence: high
- **Problem:** fetchContextMenuImageCopyPayload() (http/https branch) chains cookieStore.getAllCookies { ... URLSession.dataTask { ... DispatchQueue.main.async { completion(...) } } }. Same pyramid issue as downloadURLViaSession: nested completions, hard to follow, and if completion is called on main every time, the nesting is waste. The escaping completion parameter exacerbates fragility — if the caller doesn't hold the WebView's lifetime, the self captures in the chain risk dangling pointers.
- **Swift 6 solution:** Convert to async/await: async func fetchContextMenuImageCopyPayload(...) -> BrowserImageCopyPasteboardPayload?. Replace cookieStore.getAllCookies with async wrapper, URLSession.dataTask with URLSession.data(for:), and eliminate completion callbacks. Return the payload directly or nil on failure.
- **Fix:** Convert to: async func fetchContextMenuImageCopyPayload(...) -> BrowserImageCopyPasteboardPayload? { let cookies = await cookieStore.getAllCookies(...); let (data, response) = try await URLSession.shared.data(for: request); return BrowserImageCopyPasteboardPayload(...) }. Update call sites to use await and handle the return value. This is a linear, cancellable async chain.

### `Sources/TerminalNotificationStore.swift` (2 in scope / 8 total)

#### **[IN SCOPE]** `Sources/TerminalNotificationStore.swift:49-52` — Manual NSLock protecting mutable static sound state
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Static mutable dictionaries activePlaybackSounds and pendingCustomSoundPreparationPaths are protected with manual NSLock lock/unlock pairs. This is prone to deadlock if an exception is thrown between lock and unlock, and the structure is brittle. Modern Swift provides actor isolation which is safer and more expressive.
- **Swift 6 solution:** Replace manual NSLock + static mutable state with a static actor wrapping the mutable collections. The actor automatically serializes access and eliminates manual lock management.
- **Fix:** Create nonisolated(unsafe) private actor SoundStateManager holding the mutable collections and sound mappings. Replace lock/unlock pairs with isolated actor method calls. Callsites like retainActivePlaybackSound, releaseActivePlaybackSound, and the queueCustomSoundPreparation check become await calls to the actor. This is surgical — only the lock guards need refactoring; the rest of the sound logic stays the same.

#### **[IN SCOPE]** `Sources/TerminalNotificationStore.swift:334-346` — NSLock protecting pendingCustomSoundPreparationPaths Set with early return
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Explicit lock/unlock pair protecting read and write to pendingCustomSoundPreparationPaths. Early return at line 337 leaves the lock held if that path executes. Exception between lock() and unlock() deadlocks. Deduplication logic races against concurrent queueCustomSoundPreparation calls.
- **Swift 6 solution:** Replace with actor isolation. Deduplication check and path insertion become atomic actor-isolated methods with no manual lock management.
- **Fix:** Move pendingCustomSoundPreparationPaths into SoundStateManager actor. Create async method checkAndInsertPendingPath(_ path: String) -> Bool that atomically checks membership and inserts, returning whether caller should proceed. Remove lock/unlock from queueCustomSoundPreparation entirely.

#### [deferred] `Sources/TerminalNotificationStore.swift:366-376` — Manual NSLock for activePlaybackSounds dictionary mutations
- category: `manual-lock` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/TerminalNotificationStore.swift:803-808` — DispatchQueue.main.asyncAfter delay used for settings prompt retry loop
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/TerminalNotificationStore.swift:923-931` — Unnecessary DispatchQueue.main.async in MainActor method refreshAuthorizationStatus
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/TerminalNotificationStore.swift:1975-2030` — Completion-handler authorization flow should use async/await
- category: `completion-handler` · severity: **high** · ripple: high · confidence: high

#### [deferred] `Sources/TerminalNotificationStore.swift:1992-2029` — Nested DispatchQueue.main.async in ensureAuthorization callback
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/TerminalNotificationStore.swift:2054-2066` — Unnecessary DispatchQueue.main.async in requestAuthorizationIfNeeded callback
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

### `Sources/Update/UpdateDriver.swift` (2 in scope / 2 total)

#### **[IN SCOPE]** `Sources/Update/UpdateDriver.swift:206-214` — DispatchQueue.main.asyncAfter used as debounce/delay timing hack in UI state driver
- category: `async-after-timing` · severity: **high** · ripple: medium · confidence: high
- **Problem:** UpdateDriver.setStateAfterMinimumCheckDelay() schedules a DispatchWorkItem with asyncAfter to enforce a minimum UI display duration. This is a timing hack (sleep-based delay) in runtime app code. Repo CLAUDE.md explicitly bans such delays in shipped code. DispatchWorkItem is stored as a property for cancellation, so it's structured enough, but the asyncAfter pattern itself is the anti-pattern.
- **Swift 6 solution:** Use Task.sleep(nanoseconds:) with proper await in an async context, or model the minimum-duration constraint as a state machine with explicit state transitions triggered by app events, not timers. If a delay is genuinely required for UX, use an async Task stored in TaskGroup and await it explicitly.
- **Fix:** Refactor setStateAfterMinimumCheckDelay to be async. Use Task.sleep(nanoseconds:) for the delay instead of asyncAfter. Wrap it in a Task stored on the object for cancellation. Adjust all callers to handle async semantics. Alternatively, eliminate the delay entirely by using state-based transitions (e.g., .minimumDisplayDuration) rather than time.

#### **[IN SCOPE]** `Sources/Update/UpdateDriver.swift:229-237` — DispatchQueue.main.asyncAfter used for update-check timeout as timing hack
- category: `async-after-timing` · severity: **high** · ripple: low · confidence: high
- **Problem:** scheduleCheckTimeout() schedules a DispatchWorkItem with asyncAfter to enforce a timeout. Same issue as above: timing hack in runtime code. Repo policy forbids sleep-based timing in shipped app.
- **Swift 6 solution:** Use Task.sleep(nanoseconds:) in a stored Task, or use a Timer with explicit start/stop/cancel lifecycle. Prefer Task.sleep with cancellation checking.
- **Fix:** Extract a helper async function that awaits Task.sleep for the timeout duration, then checks if still needed and transitions state. Store the Task handle for cancellation. Remove the asyncAfter pattern entirely.

### `Sources/AgentForkSupport.swift` (1 in scope / 3 total)

#### [deferred] `Sources/AgentForkSupport.swift:8-35` — ProcessTerminationGate uses NSLock instead of actor
- category: `manual-lock` · severity: **medium** · ripple: medium · confidence: high

#### [deferred] `Sources/AgentForkSupport.swift:55-71` — CommandOutputBuffer uses NSLock instead of actor
- category: `manual-lock` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/AgentForkSupport.swift:73-290` — CommandOutputRunner uses NSLock for complex async state coordination
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** CommandOutputRunner guards five mutable properties (process, pipe, continuation, timeoutTimer, killTimer, completed, timedOut) with NSLock. The coordination between DispatchSourceTimer callbacks, process terminationHandler, and the continuation is complex and error-prone. Manual lock/unlock means race windows if unlock is forgotten or deadlock if called from a locked context. This is exactly the kind of complex async state machine that actors solve.
- **Swift 6 solution:** Refactor CommandOutputRunner as an actor with structured async/await for timeout and cleanup. Replace DispatchSourceTimer with async Task.sleep and Task cancellation. Eliminate manual locks and CheckedContinuation by using async/await methods that clients await directly.
- **Fix:** This is a deeper refactor, not surgical. (1) Convert CommandOutputRunner to an actor. (2) Replace startTimeoutTimer/startKillTimer DispatchSourceTimer callbacks with a structured async Task that sleeps and calls cancel() or terminates. (3) Replace finish() lock/unlock with direct property mutations. (4) Replace CheckedContinuation with a simple async function that runs the Process and returns the output, using Task cancellation for timeouts. Call sites change from `await withCheckedContinuation { runner.start(continuation:) }` to `await runner.run()`. The termination gate still exists but is simpler because CommandOutputRunner no longer needs to coordinate callbacks across threads.

### `Sources/App/CmuxCLIPathInstaller.swift` (1 in scope / 2 total)

#### **[IN SCOPE]** `Sources/App/CmuxCLIPathInstaller.swift:277-277` — DispatchGroup.wait() blocks calling thread synchronously waiting for async readability handlers
- category: `semaphore-block` · severity: **high** · ripple: low · confidence: high
- **Problem:** outputGroup.wait() blocks the current thread (which may be main or a sync context) until both stdout and stderr pipes finish draining via readabilityHandler callbacks. If those callbacks are delayed or the system is under load, this blocks the thread. If called from a main-thread context (e.g., through an installer UI), this can cause UI hangs. The readability handlers are inherently async; blocking on them is a concurrency anti-pattern.
- **Swift 6 solution:** Use AsyncStream or structured concurrency to collect pipe output. Wrap Pipe reading in an async function that yields data as it arrives, then await the streams concurrently without blocking. Or use ProcessPipeReader from the existing codebase in an async context.
- **Fix:** Replace DispatchGroup.wait() with Task { try await ... } that uses async pipe readers (e.g., AsyncStream or a custom async wrapper around readabilityHandler). Return output buffers after all data is read. This avoids blocking and integrates with Swift Concurrency.

#### [deferred] `Sources/App/CmuxCLIPathInstaller.swift:342-356` — NSLock protecting mutable data should be an actor for type-safe isolation
- category: `manual-lock` · severity: **medium** · ripple: medium · confidence: high

### `Sources/App/ShortcutRoutingSupport.swift` (1 in scope / 2 total)

#### [deferred] `Sources/App/ShortcutRoutingSupport.swift:455-463` — Dispatch-main async for UI state mutation after binding action
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/App/ShortcutRoutingSupport.swift:639-641` — MainActor.assumeIsolated used to access @MainActor AppDelegate from non-isolated function
- category: `sendable-mainactor` · severity: **high** · ripple: low · confidence: high
- **Problem:** The function shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst is not isolated to @MainActor, but it calls MainActor.assumeIsolated to access AppDelegate.shared (which is @MainActor). This bypasses isolation checks and is unsafe if the function is ever called from a background thread. The assumption is that the caller guarantees main-thread execution, but this is not encoded in the type system and is fragile across refactors.
- **Swift 6 solution:** Add @MainActor annotation to the shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst function itself, or restructure the function to accept the result of the AppDelegate query as a parameter (inversion of dependency). Alternatively, use a proper async continuation or MainActor.run { } if the function must remain non-isolated but the access must be thread-safe.
- **Fix:** Most direct fix: add @MainActor to the function signature. This forces all callers to be on the main thread (they are, per AppDelegate context). Surgical ripple: grep for all call sites and verify they remain in @MainActor contexts (they do, based on grep of AppDelegate.swift). Deeper refactor: pass the browserFindBarIsVisible result in as a parameter rather than querying AppDelegate inside the function, decoupling the function from main-thread assumptions.

### `Sources/App/TerminalDirectoryOpenSupport.swift` (1 in scope / 3 total)

#### [deferred] `Sources/App/TerminalDirectoryOpenSupport.swift:406-489` — Completion-handler API can be converted to async throws
- category: `completion-handler` · severity: **high** · ripple: high · confidence: high

#### [deferred] `Sources/App/TerminalDirectoryOpenSupport.swift:709-720` — NSLock protects simple value state that could be an actor
- category: `manual-lock` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/App/TerminalDirectoryOpenSupport.swift:757-761` — Semaphore blocks dispatch queue waiting for process output
- category: `semaphore-block` · severity: **high** · ripple: medium · confidence: high
- **Problem:** ServeWebOutputCollector.waitForURL() at line 757-761 blocks the calling thread with DispatchSemaphore.wait(timeout:), which is called from launchServeWebProcess at line 638. This semaphore.wait blocks on launchQueue (a background serial dispatch queue) waiting for the process to output a URL. This is a blocking pattern waiting for async work that should use callbacks or async/await instead.
- **Swift 6 solution:** Replace DispatchSemaphore with an AsyncStream-based design or a withCheckedContinuation pattern. The collector should accumulate output and notify waiting code via a continuation or async callback rather than blocking a thread.
- **Fix:** Convert ServeWebOutputCollector to track pending continuations instead of a semaphore. When a URL is parsed, signal all waiting continuations. Callers use `await collector.waitForURL()` which suspends (not blocks) until the URL is available. This preserves the timeout semantics without blocking a dispatch queue thread.

### `Sources/Auth/AuthManager.swift` (1 in scope / 3 total)

#### **[IN SCOPE]** `Sources/Auth/AuthManager.swift:23-23` — Replace DispatchQueue.main.sync with MainActor.run
- category: `dispatch-main` · severity: **high** · ripple: low · confidence: high
- **Problem:** DispatchQueue.main.sync blocks the calling thread waiting for main-thread execution. Although guarded by Thread.isMainThread check (line 19), direct use of sync is prone to deadlock risks in complex call chains. The function currentAnchor() is already @MainActor-isolated, so the modern structured-concurrency path (MainActor.run) is strictly better for both safety and clarity.
- **Swift 6 solution:** Replace DispatchQueue.main.sync { result = Self.currentAnchor() } with result = await MainActor.run { Self.currentAnchor() }. Note: this requires presentationAnchor(for:) to become async, or unwrap via a synchronous MainActor-querying helper. For the ASWebAuthenticationPresentationContextProviding protocol constraint (returns NSWindow synchronously), wrap the async call in a nested Task or use a pre-fetched cached anchor.
- **Fix:** Option A (surgical, protocol-preserving): Extract the window fetch to a cached/memoized property set at app startup time, eliminating the need to synchronously query NSApp inside the callback. Option B (refactor): Check if ASWebAuthenticationPresentationContextProviding allows async implementations in the current macOS target version; if yes, make presentationAnchor async and await MainActor.run. Option C (minimal): Keep sync but use explicit dispatchPrecondition or Task-local storage to rule out same-thread deadlock. Option A is preferred (no protocol changes, no blocking, purely architectural).

#### [deferred] `Sources/Auth/AuthManager.swift:370-370` — Replace @escaping closure parameter with async/await in runCLIAuthFlow
- category: `completion-handler` · severity: **medium** · ripple: low · confidence: medium

#### [deferred] `Sources/Auth/AuthManager.swift:584-586` — Track or await Task.detached fire-and-forget keychain store
- category: `unstructured-task` · severity: **medium** · ripple: medium · confidence: high

### `Sources/BackgroundWorkspacePrimeCoordinator.swift` (1 in scope / 2 total)

#### [deferred] `Sources/BackgroundWorkspacePrimeCoordinator.swift:24-95` — Waiter class uses NSLock with @unchecked Sendable instead of actor
- category: `manual-lock` · severity: **high** · ripple: high · confidence: high

#### **[IN SCOPE]** `Sources/BackgroundWorkspacePrimeCoordinator.swift:287-311` — Combine sink observers fire unstructured Task { @MainActor } closures without handles
- category: `combine` · severity: **high** · ripple: medium · confidence: high
- **Problem:** Two Combine sink chains (tabManager.$pendingBackgroundWorkspaceLoadIds and tabManager.$tabs) fire fire-and-forget `Task { @MainActor in }` blocks. Tasks are created but not stored or awaited, making them unstructured and impossible to cancel. Closure captures weak self/waiter/tabManager; if any are deallocated, the task silently does nothing. This pattern is fragile and violates structured concurrency principles.
- **Swift 6 solution:** Replace Combine sinks with an async/await loop using withObservationTracking or a custom async observer. Collect Task handles into an array on Waiter and cancel them explicitly on deinit or finish(). Alternatively, use TaskGroup to manage multiple observation streams under one structured handle.
- **Fix:** Refactor installReadinessObservers to not use Combine. Create an async method that awaits both observations using AsyncStream or a custom wrapper that yields when the observed values change. Wrap the async work in a Task stored on waiter for cancellation. Keep cleanup references but retire the sink/cancellable pattern.

### `Sources/BrowserWindowPortal.swift` (1 in scope / 4 total)

#### [deferred] `Sources/BrowserWindowPortal.swift:1027-1030` — Redundant DispatchQueue.main.async on @MainActor method
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/BrowserWindowPortal.swift:2233-2237` — Redundant DispatchQueue.main.async on @MainActor method for coalescing
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/BrowserWindowPortal.swift:2824-2824` — Hardcoded 30ms delay timing hack in WebView refresh pass
- category: `async-after-timing` · severity: **high** · ripple: medium · confidence: high
- **Problem:** The code uses DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) to stagger WebView refresh work passes. This violates the repo's explicit policy (CLAUDE.md line 253 of cmuxterm-hq root) prohibiting 'sleep-based timing hacks in shipped app code'. The hardcoded 30ms delay is fragile: it assumes that 30ms is always the right synchronization point between immediate, async, and delayed phases of WebView refresh. If layout churn, rendering, or other main-thread work takes longer or shorter, the timing breaks. Modern alternatives provide actual signals instead of guess-work.
- **Swift 6 solution:** Replace the 30ms asyncAfter with either: (1) a real signal from WebView (e.g., a display link wakeup, a render completion callback, or a layout notification), (2) a Task-based backpressure mechanism that waits for the previous phase to finish rather than guessing at timing, or (3) an AsyncStream that feeds phases in order without manual delay constants.
- **Fix:** Extract the three-phase refresh (immediate, async, delayed) into a structured sequence. Instead of scheduling both asyncWorkItem and delayedWorkItem immediately with a hardcoded gap, implement a state machine: run immediate phase, then await actual completion/readiness signals before moving to async phase, then await those signals before delayed phase. This is a deeper refactor that removes the timing hack entirely and makes the phases' ordering explicit in the state model. Call sites (line 3076, 3803) will be unaffected; the internal scheduling logic becomes deterministic and signal-based.

#### [deferred] `Sources/BrowserWindowPortal.swift:3250-3257` — Redundant DispatchQueue.main.async on @MainActor for deferred sync tick
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: high

### `Sources/SocketControlSettings.swift` (1 in scope / 2 total)

#### [deferred] `Sources/SocketControlSettings.swift:72-77` — NSLock protecting mutable static cache state
- category: `manual-lock` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/SocketControlSettings.swift:215-218` — Missing defer guard in resetLazyKeychainFallbackCacheForTests (lock/unlock asymmetry)
- category: `manual-lock` · severity: **high** · ripple: low · confidence: high
- **Problem:** This method directly calls .lock() and .unlock() without a defer guard. If any code between lock() and unlock() throws or returns early, the lock is not released, causing a deadlock on the next lock() attempt. The other occurrence (cachedLazyKeychainFallbackPassword, line 276) correctly uses defer, but this one does not.
- **Swift 6 solution:** Either wrap the critical section in `defer { lock.unlock() }` immediately after lock() (existing pattern at line 276), or switch the whole cache to actor isolation, which eliminates the manual lock/unlock entirely.
- **Fix:** Surgical fix: add `defer { lazyKeychainFallbackLock.unlock() }` after line 216. Better fix: migrate to actor isolation as described above, removing all manual lock management from this code path.

### `Sources/TerminalImageTransfer.swift` (1 in scope / 3 total)

#### **[IN SCOPE]** `Sources/TerminalImageTransfer.swift:82-157` — Manual NSLock protecting state that should be an actor
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** TerminalImageTransferOperation uses @unchecked Sendable with NSLock to manually guard mutable state (state, cancellationHandler). This is error-prone and requires careful lock/unlock pairing. The class manages a simple state machine (running/cancelled/finished) with handler callbacks, which is a natural actor fit. Manual lock-protected classes are fragile to refactoring and harder to reason about than actor isolation.
- **Swift 6 solution:** Convert TerminalImageTransferOperation to an actor. Mutable properties (state, cancellationHandler) become nonisolated(unsafe) or actor-isolated. Methods become async. Call sites use await. This eliminates the @unchecked Sendable declaration and NSLock entirely.
- **Fix:** Surgical refactor: change 'final class TerminalImageTransferOperation: @unchecked Sendable' to 'actor TerminalImageTransferOperation'. Remove NSLock() initialization and all lock.lock()/lock.unlock() pairs. Add 'async' to all public methods (isCancelled becomes async var or async func, etc.). Update callers: 'operation.isCancelled' → 'await operation.isCancelled', etc. All state mutations within the actor are automatically serialized.

#### [deferred] `Sources/TerminalImageTransfer.swift:246-247` — DispatchQueue.main.asyncAfter timing default in executeForTesting signature
- category: `async-after-timing` · severity: **medium** · ripple: high · confidence: high

#### [deferred] `Sources/TerminalImageTransfer.swift:269-270` — DispatchQueue.main.asyncAfter timing default in execute signature
- category: `async-after-timing` · severity: **medium** · ripple: high · confidence: high

### `Sources/TerminalNotificationPolicy.swift` (1 in scope / 1 total)

#### **[IN SCOPE]** `Sources/TerminalNotificationPolicy.swift:419-868` — Unguarded mutable state in NotificationHookProcessRun; race on didComplete and continuation
- category: `unchecked-sendable-race` · severity: **critical** · ripple: low · confidence: high
- **Problem:** NotificationHookProcessRun is marked @unchecked Sendable but has mutable state (didComplete, continuation, processId, file descriptors) that is accessed from multiple DispatchQueue callbacks and the outer async/await context without explicit synchronization. The `complete()` method reads/writes didComplete and continuation with only a simple guard, but multiple event sources (timeoutReached, processExited, readSource event handlers) can call it concurrently. Data race on didComplete flag and continuation pointer.
- **Swift 6 solution:** Convert NotificationHookProcessRun to an actor. The queue-based work becomes non-isolated methods or nonisolated(unsafe) with interior synchronization if needed. The continuation and state become actor-isolated, eliminating data races by construction. Alternatively, synchronize all mutable state access with a lock, but actor is cleaner.
- **Fix:** 1. Make NotificationHookProcessRun an actor (remove @unchecked Sendable). 2. Mark mutable state properties as actor-isolated (default). 3. Wrap the dispatch queue async blocks with nonisolated(unsafe) { Self.actor.methodName() } if callbacks cannot be directly async, or use async-throws Task spawning. 4. Ensure `complete()` is actor-isolated; callers resume continuation under actor lock. 5. Verify no public API changes (the run() method stays async). Ripple is LOW if the class remains private (line 419 says private).

### `Sources/TextBoxInput.swift` (1 in scope / 5 total)

#### [deferred] `Sources/TextBoxInput.swift:418-434` — Fire-and-forget Task.detached without cancellation handle
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/TextBoxInput.swift:1989-2004` — Fire-and-forget Task with cancellation storage is fragile
- category: `unstructured-task` · severity: **medium** · ripple: medium · confidence: medium

#### [deferred] `Sources/TextBoxInput.swift:2895-2938` — Notification observer closures wrap main-queue code in unnecessary Task
- category: `unstructured-task` · severity: **medium** · ripple: low · confidence: high

#### **[IN SCOPE]** `Sources/TextBoxInput.swift:2970-2985` — DispatchSourceTimer for wait timeout instead of Task timeout
- category: `async-after-timing` · severity: **high** · ripple: medium · confidence: high
- **Problem:** armObservationTimeout uses DispatchSource.makeTimerSource(queue: .main) to set a timeout for observation checks. The timer is manually scheduled and resumed, and its event handler wraps callback in `Task { @MainActor in ... }`. This is a timing hack: the timeout reschedules work on main instead of using Swift's structured concurrency timeouts (Task.sleep, withTimeoutChecking, or similar). This can hang the main thread if timer logic interleaves poorly.
- **Swift 6 solution:** Use `Task { try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)); onExhausted?() }` or wrap the observation loop in a timeout guard with `AsyncStream` and `.timeout()` operator.
- **Fix:** Replace the DispatchSource timer with a background Task that sleeps for the timeout and calls onExhausted(). Cancel the task in removeObservers(). This removes the dispatch tier and simplifies cleanup.

#### [deferred] `Sources/TextBoxInput.swift:3544-3605` — DispatchQueue.main.async wrapping @MainActor code inside @MainActor context
- category: `dispatch-main` · severity: **medium** · ripple: low · confidence: medium

### `Sources/Update/UpdateController.swift` (1 in scope / 6 total)

#### **[IN SCOPE]** `Sources/Update/UpdateController.swift:153-159` — Replace Timer.scheduledTimer background probe with Task.sleep in a structured loop
- category: `async-after-timing` · severity: **high** · ripple: low · confidence: high
- **Problem:** Timer.scheduledTimer repeats: true creates a long-lived repeating closure that must be manually invalidated in deinit. If invalidation is missed or delayed, the timer continues firing on a background thread, causing stale closures to execute. The [weak self] guard happens at the scheduler level, not guaranteed to prevent use-after-free. This is a classic source of crashes in app lifecycle edge cases.
- **Swift 6 solution:** Use a Task that loops with Task.sleep(nanoseconds:) between probes, checked against a cancellation flag. On deinit or when stopping, the task is cancelled automatically. The loop is explicit and testable.
- **Fix:** Store a Task handle in backgroundProbeTask instead of Timer. On init or start, spawn Task(priority: .userInitiated) { while !Task.isCancelled { ... Task.sleep(...) ... } }. Cancel in deinit. This is safer and requires no manual invalidation.

#### [deferred] `Sources/Update/UpdateController.swift:181-184` — Replace Combine sink with async/await for state observation and main-thread dispatch
- category: `combine` · severity: **medium** · ripple: medium · confidence: high

#### [deferred] `Sources/Update/UpdateController.swift:230-232` — Replace DispatchQueue.main.asyncAfter with Task.sleep for retry delay
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

#### [deferred] `Sources/Update/UpdateController.swift:265-270` — Replace DispatchWorkItem-based retry loop with async/await recursion or structured Task
- category: `async-after-timing` · severity: **medium** · ripple: medium · confidence: high

#### [deferred] `Sources/Update/UpdateController.swift:288-293` — Replace Combine Publishers.CombineLatest with async/await observation
- category: `combine` · severity: **medium** · ripple: medium · confidence: high

#### [deferred] `Sources/Update/UpdateController.swift:303-318` — Replace DispatchWorkItem auto-dismiss timer with Task.sleep in async context
- category: `async-after-timing` · severity: **medium** · ripple: low · confidence: high

### `Sources/WindowDragHandleView.swift` (1 in scope / 4 total)

#### [deferred] `Sources/WindowDragHandleView.swift:12-32` — Convert WindowMouseMovedEventsCoordinator to actor
- category: `manual-lock` · severity: **high** · ripple: high · confidence: high

#### [deferred] `Sources/WindowDragHandleView.swift:12-12` — Remove nonisolated(unsafe) on mutable Dictionary in WindowMouseMovedEventsCoordinator
- category: `manual-lock` · severity: **medium** · ripple: high · confidence: high

#### **[IN SCOPE]** `Sources/WindowDragHandleView.swift:76-96` — Convert WindowDragHandleBreadcrumbLimiter to actor
- category: `manual-lock` · severity: **high** · ripple: medium · confidence: high
- **Problem:** WindowDragHandleBreadcrumbLimiter uses NSLock to protect mutable static state (lastEmissionByKey dictionary). The state is isolated and accessed only for rate-limiting breadcrumb telemetry. Manual lock/unlock is error-prone and verbose. This is exactly what actors were designed for.
- **Swift 6 solution:** Convert WindowDragHandleBreadcrumbLimiter to an actor with async shouldEmit method. Actor isolation replaces NSLock.
- **Fix:** 1. Convert enum to actor. 2. Remove NSLock. 3. Move lastEmissionByKey into actor storage. 4. Mark shouldEmit as mutating async method. 5. Update all call sites (line 108) to await the result. Call sites are likely on AppKit event path; if so, wrap in Task { @MainActor in ... } or use nonisolated (unsafe) shouldEmitSync wrapper for fire-and-forget telemetry.

#### [deferred] `Sources/WindowDragHandleView.swift:437-457` — Convert MinimalModeTitlebarControlHitRegionRegistry to actor
- category: `manual-lock` · severity: **medium** · ripple: medium · confidence: high

## Deferred files (catalog only)

### `CLI/cmux.swift` (10 findings, deferred)

- `CLI/cmux.swift:2098` `semaphore-block` (high/high) — Block on DispatchSemaphore waiting for socket connection in CLI startup
- `CLI/cmux.swift:2149` `semaphore-block` (high/high) — Block on DispatchSemaphore waiting for filesystem path existence in CLI startup
- `CLI/cmux.swift:8582` `semaphore-block` (high/medium) — URLSessionWebSocketDelegate uses semaphore.wait() to synchronously block until open
- `CLI/cmux.swift:8766` `semaphore-block` (high/medium) — receiveSync() blocks on DispatchSemaphore waiting for URLSessionWebSocketTask callback
- `CLI/cmux.swift:8794` `semaphore-block` (high/medium) — sendSync() blocks on DispatchSemaphore waiting for URLSessionWebSocketTask callback
- `CLI/cmux.swift:16619` `unchecked-sendable-race` (medium/medium) — CodexTeamsAsyncBox<Value> marked @unchecked Sendable with mutable stored property protected only by NSLock
- `CLI/cmux.swift:16716` `semaphore-block` (high/medium) — receiveObject() blocks on DispatchSemaphore waiting for websocket receive callback
- `CLI/cmux.swift:16850` `semaphore-block` (medium/low) — reconcileWaiter semaphore used in infinite retry loop with timeout
- `CLI/cmux.swift:17567` `semaphore-block` (high/medium) — Multiple blocking semaphores in process execution wait logic
- `CLI/cmux.swift:22473` `semaphore-block` (medium/low) — waitForCodexTranscriptChange() uses semaphore.wait(timeout:) to block on filesystem events

### `CLI/cmux_open.swift` (4 findings, deferred)

- `CLI/cmux_open.swift:3581` `semaphore-block` (high/high) — DispatchSemaphore.wait() blocks CLI init path waiting for async FileHandle read
- `CLI/cmux_open.swift:3625` `semaphore-block` (high/high) — DispatchSemaphore.wait() blocks CLI init path waiting for URLSession network request
- `CLI/cmux_open.swift:3701` `manual-lock` (medium/low) — Manual NSLock protecting mutable cache state should be an actor
- `CLI/cmux_open.swift:4035` `semaphore-block` (medium/low) — DispatchSemaphore event loop with polling waits for file modification in tight loop

### `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift` (2 findings, deferred)

- `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift:8` `unchecked-sendable-race` (medium/medium) — DebugEventLog @unchecked Sendable with mutable entries array protected only by DispatchQueue
- `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift:154` `semaphore-block` (medium/low) — DispatchQueue.sync blocks calling thread in DebugEventLog.dump()

### `Packages/CMUXWorkstream/Sources/CMUXWorkstream/WorkstreamStore.swift` (2 findings, deferred)

- `Packages/CMUXWorkstream/Sources/CMUXWorkstream/WorkstreamStore.swift:77` `unstructured-task` (medium/medium) — Unstructured Task fire-and-forget in transport.subscribe callback
- `Packages/CMUXWorkstream/Sources/CMUXWorkstream/WorkstreamStore.swift:125` `unstructured-task` (medium/low) — Unstructured Task fire-and-forget in ingest() method

### `Packages/CMUXWorkstream/Tests/CMUXWorkstreamTests/WorkstreamStoreTests.swift` (1 findings, deferred)

- `Packages/CMUXWorkstream/Tests/CMUXWorkstreamTests/WorkstreamStoreTests.swift:216` `unchecked-sendable-race` (medium/low) — Replace @unchecked Sendable + NSLock with actor isolation

### `Sources/App/AgentHibernationController.swift` (1 findings, deferred)

- `Sources/App/AgentHibernationController.swift:155` `async-after-timing` (medium/low) — DispatchSourceTimer for periodic 30-second hibernation evaluation

### `Sources/App/MenuBarExtraController.swift` (2 findings, deferred)

- `Sources/App/MenuBarExtraController.swift:2` `combine` (medium/low) — Combine import and AnyCancellable for notificationMenuSnapshot observation
- `Sources/App/MenuBarExtraController.swift:38` `completion-handler` (medium/medium) — Multiple @escaping closure callback parameters in MenuBarExtraController.init

### `Sources/App/SettingsWindowPresenter.swift` (1 findings, deferred)

- `Sources/App/SettingsWindowPresenter.swift:48` `unstructured-task` (medium/low) — Store Task handle for window focus and tie to window lifecycle

### `Sources/App/WorkspaceRuntimeSettings.swift` (1 findings, deferred)

- `Sources/App/WorkspaceRuntimeSettings.swift:344` `manual-lock` (medium/medium) — Replace NSLock with actor for AgentHibernationTrackingGate

### `Sources/AppDelegate.swift` (9 findings, deferred)

- `Sources/AppDelegate.swift:9` `combine` (high/high) — Replace Combine with async/await throughout
- `Sources/AppDelegate.swift:1749` `unstructured-task` (medium/low) — Store and cancel ghosttyCrashBreadcrumbTask explicitly
- `Sources/AppDelegate.swift:3767` `async-after-timing` (medium/low) — Replace asyncAfter delay in sessionAutosave retry with state-driven retry
- `Sources/AppDelegate.swift:5457` `async-after-timing` (medium/low) — Replace dual asyncAfter calls in drop-and-focus handler with async state polling
- `Sources/AppDelegate.swift:8570` `async-after-timing` (medium/low) — Replace 3s timeout asyncAfter in send command with proper async timeout
- `Sources/AppDelegate.swift:8877` `async-after-timing` (medium/low) — Replace asyncAfter timeout in waitForDebugStressCondition with Task.sleep
- `Sources/AppDelegate.swift:10632` `async-after-timing` (medium/medium) — Replace 8s timeout asyncAfter in waitForContexts with proper async timeout
- `Sources/AppDelegate.swift:10731` `async-after-timing` (medium/medium) — Replace asyncAfter timeout in waitForSurfaceId with proper async pattern
- `Sources/AppDelegate.swift:10931` `async-after-timing` (medium/low) — Replace 8s timeout asyncAfter in setupMultiWindowNotificationUITest with proper async

### `Sources/AppIconDockTilePlugin.swift` (1 findings, deferred)

- `Sources/AppIconDockTilePlugin.swift:71` `dispatch-main` (medium/low) — Unnecessary DispatchQueue.main.async inside KVO observation callback already on main queue

### `Sources/AppearanceSettings.swift` (1 findings, deferred)

- `Sources/AppearanceSettings.swift:41` `manual-lock` (medium/medium) — Static NSLock protecting mutable function pointer for testing, should use module isolation or Sendable wrapper

### `Sources/CloudVMActionLauncher.swift` (1 findings, deferred)

- `Sources/CloudVMActionLauncher.swift:224` `manual-lock` (medium/high) — ProcessOutputCollector uses NSLock with @unchecked Sendable instead of actor

### `Sources/CmuxConfigExecutor.swift` (2 findings, deferred)

- `Sources/CmuxConfigExecutor.swift:136` `completion-handler` (medium/medium) — Convert onAuthorized callback to async/await for shell command execution
- `Sources/CmuxConfigExecutor.swift:243` `completion-handler` (medium/low) — Convert completion-handler alert callback to async/await

### `Sources/CmuxEventLogWriter.swift` (1 findings, deferred)

- `Sources/CmuxEventLogWriter.swift:58` `dispatch-main` (medium/low) — DispatchQueue.sync in flushForTesting causes unnecessary blocking

### `Sources/CmuxTopSnapshot.swift` (1 findings, deferred)

- `Sources/CmuxTopSnapshot.swift:132` `sendable-mainactor` (medium/low) — Remove @unchecked Sendable on immutable value-only class

### `Sources/CommandClickFileOpenRouter.swift` (1 findings, deferred)

- `Sources/CommandClickFileOpenRouter.swift:67` `dispatch-main` (medium/low) — DispatchQueue.main.async deferral in MainActor context

### `Sources/CommandPalette/CommandPaletteSearch.swift` (1 findings, deferred)

- `Sources/CommandPalette/CommandPaletteSearch.swift:1282` `completion-handler` (medium/low) — Convert shouldCancel completion handler to async/await

### `Sources/ContentView.swift` (15 findings, deferred)

- `Sources/ContentView.swift:3` `combine` (medium/high) — Replace Combine sink with async/await or AsyncSequence
- `Sources/ContentView.swift:439` `async-after-timing` (medium/medium) — Replace asyncAfter retry loop with async recursion + Task.sleep
- `Sources/ContentView.swift:509` `async-after-timing` (medium/low) — Replace DispatchSource timer for focus lock polling with Task.sleep loop
- `Sources/ContentView.swift:1766` `async-after-timing` (medium/low) — Replace asyncAfter + DispatchWorkItem with Task.sleep and async/await
- `Sources/ContentView.swift:1818` `async-after-timing` (medium/low) — Replace DispatchSource timer with AsyncStream or Task.sleep loop
- `Sources/ContentView.swift:2701` `async-after-timing` (medium/low) — Replace asyncAfter with Task.sleep for file explorer state sync timeout
- `Sources/ContentView.swift:5096` `unstructured-task` (high/low) — Task.detached fire-and-forget should store handle or be awaited
- `Sources/ContentView.swift:5301` `unstructured-task` (medium/low) — Task.detached for command palette search should have explicit cancellation
- `Sources/ContentView.swift:6177` `unstructured-task` (high/medium) — Task fire-and-forget without explicit storage for cancellation
- `Sources/ContentView.swift:9151` `async-after-timing` (medium/low) — Replace asyncAfter timeout with Task.sleep in a managed Task
- `Sources/ContentView.swift:12208` `async-after-timing` (medium/low) — Replace asyncAfter drag failsafe timer with Task.sleep
- `Sources/ContentView.swift:12457` `async-after-timing` (medium/low) — Replace asyncAfter keyboard shortcut hint delay with Task.sleep
- `Sources/ContentView.swift:13444` `async-after-timing` (medium/low) — Replace asyncAfter + nested Task with direct Task.sleep
- `Sources/ContentView.swift:13823` `manual-lock` (medium/medium) — Replace NSLock with Actor or nonisolated(unsafe) static for hint width cache
- `Sources/ContentView.swift:16173` `async-after-timing` (medium/low) — Replace Timer + Task wrapper with AsyncStream or Task.sleep loop

### `Sources/ExtensionWorktreePrototype.swift` (3 findings, deferred)

- `Sources/ExtensionWorktreePrototype.swift:9` `manual-lock` (medium/low) — NSLock protecting continuation state should be an actor
- `Sources/ExtensionWorktreePrototype.swift:49` `unstructured-task` (medium/low) — Task.detached result discarded without structured cancellation
- `Sources/ExtensionWorktreePrototype.swift:171` `unstructured-task` (medium/low) — Task.detached stored without cancellation tracking

### `Sources/Feed/FeedPanelView.swift` (2 findings, deferred)

- `Sources/Feed/FeedPanelView.swift:941` `unstructured-task` (medium/low) — Fire-and-forget Task closures in FeedRowActions without proper isolation
- `Sources/Feed/FeedPanelView.swift:3408` `unstructured-task` (medium/low) — Fire-and-forget Task in Coordinator.blurField without lifecycle management

### `Sources/Feed/FeedPanelViewModel.swift` (3 findings, deferred)

- `Sources/Feed/FeedPanelViewModel.swift:22` `unstructured-task` (medium/low) — Fire-and-forget Task in notification callback with no error handling
- `Sources/Feed/FeedPanelViewModel.swift:41` `unstructured-task` (medium/low) — Fire-and-forget Task in withObservationTracking onChange callback
- `Sources/Feed/FeedPanelViewModel.swift:49` `unstructured-task` (medium/low) — Fire-and-forget Task from nonisolated context with MainActor closure

### `Sources/Feed/FeedTextEditorDebugWindowController.swift` (1 findings, deferred)

- `Sources/Feed/FeedTextEditorDebugWindowController.swift:357` `dispatch-main` (medium/low) — Use @MainActor or direct mutation instead of DispatchQueue.main.async

### `Sources/FileExplorerSearchController.swift` (1 findings, deferred)

- `Sources/FileExplorerSearchController.swift:374` `sendable-mainactor` (medium/low) — Remove @unchecked Sendable on immutable wrapper with no hidden state

### `Sources/FileExplorerView.swift` (3 findings, deferred)

- `Sources/FileExplorerView.swift:221` `combine` (medium/low) — Replace Combine debounce + Task with AsyncStream or structured concurrency
- `Sources/FileExplorerView.swift:1199` `combine` (medium/low) — Replace Combine debounce pipeline with structured async debouncing
- `Sources/FileExplorerView.swift:1523` `unstructured-task` (medium/low) — Remove redundant fire-and-forget Task in controlTextDidChange

### `Sources/Find/BrowserSearchOverlay.swift` (5 findings, deferred)

- `Sources/Find/BrowserSearchOverlay.swift:233` `dispatch-main` (medium/low) — DispatchQueue.main.async in Coordinator.focusField (fallback path)
- `Sources/Find/BrowserSearchOverlay.swift:250` `dispatch-main` (medium/low) — DispatchQueue.main.async in controlTextDidBeginEditing, a delegate callback
- `Sources/Find/BrowserSearchOverlay.swift:261` `dispatch-main` (medium/low) — DispatchQueue.main.async in controlTextDidEndEditing, a delegate callback
- `Sources/Find/BrowserSearchOverlay.swift:279` `dispatch-main` (medium/low) — DispatchQueue.main.async in control(_:textView:doCommandBy:) delegate callback
- `Sources/Find/BrowserSearchOverlay.swift:380` `dispatch-main` (medium/low) — DispatchQueue.main.async in updateNSView, which is called from SwiftUI main context

### `Sources/Find/FindTextFieldSupport.swift` (2 findings, deferred)

- `Sources/Find/FindTextFieldSupport.swift:269` `unstructured-task` (medium/low) — Fire-and-forget DispatchQueue.main.async closure in key event monitor without structured storage
- `Sources/Find/FindTextFieldSupport.swift:293` `unstructured-task` (medium/low) — Fire-and-forget DispatchQueue.main.async in cmuxRestoreRememberedSelection without cancellation handle

### `Sources/GhosttyConfig.swift` (1 findings, deferred)

- `Sources/GhosttyConfig.swift:14` `manual-lock` (medium/high) — Replace NSLock with actor for static config cache

### `Sources/GhosttyCrashBreadcrumb.swift` (1 findings, deferred)

- `Sources/GhosttyCrashBreadcrumb.swift:20` `unstructured-task` (medium/low) — Unnecessary Task.detached wrapping synchronous blocking call

### `Sources/GhosttyTerminalView.swift` (14 findings, deferred)

- `Sources/GhosttyTerminalView.swift:6` `combine` (medium/low) — Replace Combine delay and sink with async/await stream
- `Sources/GhosttyTerminalView.swift:316` `manual-lock` (medium/low) — Refactor temporaryImageOwnershipLock to actor
- `Sources/GhosttyTerminalView.swift:1719` `manual-lock` (medium/medium) — Refactor appRegistryLock to actor for Ghostty app lifecycle
- `Sources/GhosttyTerminalView.swift:1734` `manual-lock` (medium/low) — Refactor _tickLock to @MainActor property guard
- `Sources/GhosttyTerminalView.swift:1923` `manual-lock` (medium/low) — Refactor backgroundLogLock to actor for debug logging
- `Sources/GhosttyTerminalView.swift:1969` `async-after-timing` (medium/low) — Replace asyncAfter scroll timeout with Task.sleep
- `Sources/GhosttyTerminalView.swift:3424` `dispatch-main` (high/medium) — Replace DispatchQueue.main.sync with MainActor.run and @MainActor refactoring
- `Sources/GhosttyTerminalView.swift:4132` `dispatch-main` (high/medium) — Replace performOnMain helper with direct @MainActor refactoring
- `Sources/GhosttyTerminalView.swift:4942` `manual-lock` (medium/low) — Refactor GhosttyRenderedFrameNotificationDemand lock to actor
- `Sources/GhosttyTerminalView.swift:4965` `manual-lock` (medium/low) — Refactor GhosttyTickNotificationDemand lock to actor
- `Sources/GhosttyTerminalView.swift:4991` `manual-lock` (medium/medium) — Refactor GhosttyMetalLayer lock to MainActor isolation
- `Sources/GhosttyTerminalView.swift:5033` `manual-lock` (high/high) — Refactor TerminalSurfaceRegistry lock to actor
- `Sources/GhosttyTerminalView.swift:5255` `manual-lock` (medium/low) — Refactor debugMetadataLock to @MainActor or nonisolated async
- `Sources/GhosttyTerminalView.swift:5284` `manual-lock` (medium/low) — Refactor debugForceRefreshCountLock to @MainActor property

### `Sources/KeyboardShortcutSettingsFileStore.swift` (6 findings, deferred)

- `Sources/KeyboardShortcutSettingsFileStore.swift:1` `combine` (medium/low) — Replace Combine ObservableObject with @Observable
- `Sources/KeyboardShortcutSettingsFileStore.swift:17` `combine` (medium/low) — Replace Combine publisher chains with async/await
- `Sources/KeyboardShortcutSettingsFileStore.swift:61` `manual-lock` (high/high) — Replace NSLock with actor for state synchronization
- `Sources/KeyboardShortcutSettingsFileStore.swift:65` `combine` (medium/low) — Replace Combine with async NotificationCenter observation
- `Sources/KeyboardShortcutSettingsFileStore.swift:104` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async with structured async/await
- `Sources/KeyboardShortcutSettingsFileStore.swift:1477` `dispatch-main` (medium/medium) — Thread.isMainThread check is fragile; use @MainActor or structured dispatch

### `Sources/NotificationsPage.swift` (2 findings, deferred)

- `Sources/NotificationsPage.swift:28` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async with @MainActor or Task @MainActor
- `Sources/NotificationsPage.swift:56` `async-after-timing` (medium/low) — Replace asyncAfter delay with Task-based deferred focus with cancellation

### `Sources/Panels/BrowserPanel.swift` (15 findings, deferred)

- `Sources/Panels/BrowserPanel.swift:2518` `unchecked-sendable-race` (high/medium) — @unchecked Sendable SchemeTaskState with unprotected isStopped and callbacksInFlight reads
- `Sources/Panels/BrowserPanel.swift:2524` `manual-lock` (high/medium) — NSLock protecting sessions and activeSchemeTasks in CmuxDiffViewerURLSchemeHandler
- `Sources/Panels/BrowserPanel.swift:2782` `semaphore-block` (critical/medium) — NSCondition.wait() blocks streamQueue waiting for callbacks to drain
- `Sources/Panels/BrowserPanel.swift:3346` `combine` (medium/medium) — Combine .delay() + .sink() in searchNeedle pipeline replaceable by AsyncStream
- `Sources/Panels/BrowserPanel.swift:4439` `dispatch-main` (medium/medium) — DispatchQueue.main.async to mutation in UI-bound method
- `Sources/Panels/BrowserPanel.swift:5038` `dispatch-main` (medium/medium) — DispatchQueue.main.async in AppKit responder-chain mutation
- `Sources/Panels/BrowserPanel.swift:5448` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter timing hack in web view loading
- `Sources/Panels/BrowserPanel.swift:6179` `dispatch-main` (medium/medium) — Unnecessary DispatchQueue.main.async for objectWillChange notification
- `Sources/Panels/BrowserPanel.swift:6296` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter timing hack in developer tools dismissal
- `Sources/Panels/BrowserPanel.swift:6601` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter timing hack for developer tools visibility loss check
- `Sources/Panels/BrowserPanel.swift:6834` `dispatch-main` (medium/medium) — Redundant DispatchQueue.main.async for search focus notification
- `Sources/Panels/BrowserPanel.swift:6837` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter hardcoded 50ms delay in search focus
- `Sources/Panels/BrowserPanel.swift:7376` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter retry loop in address bar focus restoration
- `Sources/Panels/BrowserPanel.swift:7505` `async-after-timing` (medium/medium) — DispatchQueue.main.asyncAfter retry in developer tools restoration
- `Sources/Panels/BrowserPanel.swift:7833` `manual-lock` (medium/medium) — NSLock protecting activeDownloads dictionary in download delegate

### `Sources/Panels/BrowserPanelView.swift` (7 findings, deferred)

- `Sources/Panels/BrowserPanelView.swift:1061` `combine` (medium/low) — Replace NotificationCenter.default.publisher with AsyncStream-based approach
- `Sources/Panels/BrowserPanelView.swift:1106` `combine` (medium/medium) — Replace @Published $entries observer with AsyncStream or async binding
- `Sources/Panels/BrowserPanelView.swift:1658` `async-after-timing` (medium/medium) — Remove asyncAfter timing hack, use async animation frame syncing
- `Sources/Panels/BrowserPanelView.swift:2151` `unstructured-task` (medium/low) — Task.detached result immediately awaited; use async function instead
- `Sources/Panels/BrowserPanelView.swift:5736` `completion-handler` (high/low) — Replace WKWebView.evaluateJavaScript completion handler with async/await wrapper
- `Sources/Panels/BrowserPanelView.swift:5756` `async-after-timing` (high/medium) — Replace DispatchWorkItem debounce with structured Task cancellation
- `Sources/Panels/BrowserPanelView.swift:6874` `unstructured-task` (medium/high) — Replace closure-based event handlers with AsyncStream for structured observation

### `Sources/Panels/BrowserPopupWindowController.swift` (1 findings, deferred)

- `Sources/Panels/BrowserPopupWindowController.swift:230` `unstructured-task` (medium/low) — Fire-and-forget Tasks in KVO observation closures without cancellation

### `Sources/Panels/BrowserWebAuthnSupport.swift` (1 findings, deferred)

- `Sources/Panels/BrowserWebAuthnSupport.swift:1163` `completion-handler` (medium/low) — Convert WKScriptMessageHandlerWithReply completion handler to async/await

### `Sources/Panels/MarkdownPanel.swift` (3 findings, deferred)

- `Sources/Panels/MarkdownPanel.swift:171` `unstructured-task` (medium/low) — Unstructured Task without MainActor constraint in @MainActor saveTextContent()
- `Sources/Panels/MarkdownPanel.swift:295` `dispatch-main` (medium/low) — DispatchQueue.main.async called from file watcher background queue in MarkdownPanel
- `Sources/Panels/MarkdownPanel.swift:306` `dispatch-main` (medium/low) — Second DispatchQueue.main.async in file watcher (duplication)

### `Sources/Panels/MarkdownPanelView.swift` (2 findings, deferred)

- `Sources/Panels/MarkdownPanelView.swift:222` `async-after-timing` (medium/low) — Replace Task.sleep with cancellable auto-dismiss mechanism
- `Sources/Panels/MarkdownPanelView.swift:237` `async-after-timing` (medium/low) — Replace asyncAfter loop with Task-based animation timing

### `Sources/Panels/MarkdownRemoteImageLoader.swift` (3 findings, deferred)

- `Sources/Panels/MarkdownRemoteImageLoader.swift:331` `manual-lock` (high/high) — Mutable class protected by NSLock should be an actor
- `Sources/Panels/MarkdownRemoteImageLoader.swift:351` `completion-handler` (high/high) — Completion-handler chains across async network operations should be AsyncStream
- `Sources/Panels/MarkdownRemoteImageLoader.swift:411` `async-after-timing` (medium/low) — Timeout via asyncAfter should use Task.withDeadline or NWConnection timeout

### `Sources/Panels/MarkdownWebRenderer.swift` (2 findings, deferred)

- `Sources/Panels/MarkdownWebRenderer.swift:378` `unstructured-task` (medium/medium) — Fire-and-forget Task for URL scheme response handling without explicit lifecycle management
- `Sources/Panels/MarkdownWebRenderer.swift:419` `unstructured-task` (medium/medium) — Task.detached fire-and-forget for image loading without structured containment

### `Sources/Panels/ReactGrab.swift` (3 findings, deferred)

- `Sources/Panels/ReactGrab.swift:105` `unstructured-task` (medium/low) — Task.detached fire-and-forget with internal cleanup task
- `Sources/Panels/ReactGrab.swift:400` `completion-handler` (medium/low) — webView.evaluateJavaScript uses @escaping completion handler
- `Sources/Panels/ReactGrab.swift:419` `completion-handler` (medium/low) — webView.evaluateJavaScript with nil completionHandler is fire-and-forget

### `Sources/PortScanner.swift` (6 findings, deferred)

- `Sources/PortScanner.swift:15` `unchecked-sendable-race` (high/high) — Replace @unchecked Sendable DispatchQueue controller with actor
- `Sources/PortScanner.swift:135` `async-after-timing` (medium/medium) — Replace asyncAfter burst scheduler with structured Task timing
- `Sources/PortScanner.swift:169` `unstructured-task` (medium/low) — Store or track Task handle for runScan fire-and-forget
- `Sources/PortScanner.swift:302` `unstructured-task` (medium/low) — Store or track Task handle for runTrackedAgentScan fire-and-forget
- `Sources/PortScanner.swift:401` `unstructured-task` (medium/low) — Store or track Task handle for deliverAgentResults fire-and-forget
- `Sources/PortScanner.swift:422` `completion-handler` (medium/low) — Remove withCheckedContinuation bridge; use direct async coordination

### `Sources/PostHogAnalytics.swift` (2 findings, deferred)

- `Sources/PostHogAnalytics.swift:107` `async-after-timing` (medium/medium) — Replace Timer.scheduledTimer with Clock/AsyncStream for periodic telemetry
- `Sources/PostHogAnalytics.swift:193` `manual-lock` (high/high) — Replace DispatchQueue.sync / NSLock with actor-based isolation

### `Sources/RestorableAgentSession.swift` (3 findings, deferred)

- `Sources/RestorableAgentSession.swift:1057` `unstructured-task` (medium/low) — Redundant Task.detached with immediate .value await
- `Sources/RestorableAgentSession.swift:1500` `unstructured-task` (medium/low) — Redundant Task.detached with immediate .value await
- `Sources/RestorableAgentSession.swift:1514` `unstructured-task` (medium/low) — Redundant Task.detached with immediate .value await

### `Sources/RightSidebarToolPanel.swift` (2 findings, deferred)

- `Sources/RightSidebarToolPanel.swift:151` `combine` (medium/medium) — Replace Combine Publishers.MergeMany with async/await observation
- `Sources/RightSidebarToolPanel.swift:282` `async-after-timing` (medium/low) — Use Task with async animation timing instead of DispatchQueue.main.asyncAfter

### `Sources/Search/GlobalSearchPanelCaptureManager.swift` (3 findings, deferred)

- `Sources/Search/GlobalSearchPanelCaptureManager.swift:60` `unstructured-task` (medium/low) — Store and manage Task lifetimes for capture operations
- `Sources/Search/GlobalSearchPanelCaptureManager.swift:125` `unstructured-task` (medium/low) — Store and manage Task lifetimes for markdown capture operations
- `Sources/Search/GlobalSearchPanelCaptureManager.swift:183` `async-after-timing` (medium/medium) — Replace DispatchSourceTimer debouncing with Task-based cancellable delay

### `Sources/SessionIndexView.swift` (1 findings, deferred)

- `Sources/SessionIndexView.swift:450` `dispatch-main` (medium/low) — Redundant DispatchQueue.main.async for @MainActor closure

### `Sources/TabManager.swift` (18 findings, deferred)

- `Sources/TabManager.swift:6` `combine` (medium/medium) — Replace Combine sink patterns with async/await
- `Sources/TabManager.swift:14` `unchecked-sendable-race` (high/high) — WorkspaceGitMetadataWatcherCallbackBox @unchecked Sendable is not thread-safe
- `Sources/TabManager.swift:28` `unchecked-sendable-race` (high/high) — WorkspaceGitMetadataWatcher @unchecked Sendable with mutable state
- `Sources/TabManager.swift:118` `async-after-timing` (medium/medium) — Replace asyncAfter debounce with structured async timing
- `Sources/TabManager.swift:118` `async-after-timing` (medium/medium) — Debounce using fixed asyncAfter delay instead of structured debounce pattern
- `Sources/TabManager.swift:739` `async-after-timing` (medium/low) — asyncAfter timing hack for notification burst coalescing
- `Sources/TabManager.swift:797` `manual-lock` (medium/medium) — NSLock protecting mutable state in VsyncIOSurfaceTimelineState
- `Sources/TabManager.swift:864` `dispatch-main` (critical/low) — DispatchQueue.main.sync called from CVDisplayLink callback
- `Sources/TabManager.swift:2696` `async-after-timing` (medium/low) — asyncAfter timing hack for welcome message send delay
- `Sources/TabManager.swift:2740` `async-after-timing` (medium/low) — asyncAfter timing hack for observer cleanup timeout
- `Sources/TabManager.swift:4773` `unchecked-sendable-race` (high/high) — CommandRunState @unchecked Sendable with NSLock but incomplete protection
- `Sources/TabManager.swift:4936` `async-after-timing` (medium/low) — asyncAfter timing hack for process SIGKILL retry
- `Sources/TabManager.swift:4987` `async-after-timing` (medium/low) — asyncAfter timing hack for process timeout scheduling
- `Sources/TabManager.swift:8489` `async-after-timing` (medium/medium) — asyncAfter timing hack for terminal condition wait timeout
- `Sources/TabManager.swift:8571` `async-after-timing` (medium/low) — asyncAfter timing hack for panel condition wait timeout
- `Sources/TabManager.swift:8651` `async-after-timing` (medium/low) — asyncAfter timing hack for split test setup delay
- `Sources/TabManager.swift:9265` `async-after-timing` (medium/low) — asyncAfter timing hack for panel-close-iteration timeout
- `Sources/TabManager.swift:9577` `async-after-timing` (medium/low) — asyncAfter timing hack for workspace-cycle timeout in test

### `Sources/TerminalController.swift` (23 findings, deferred)

- `Sources/TerminalController.swift:121` `manual-lock` (high/high) — NSLock for listener state should be actor isolation
- `Sources/TerminalController.swift:149` `manual-lock` (medium/low) — NSLock for socket listener failure capture should be actor or Sendable wrapper
- `Sources/TerminalController.swift:364` `unstructured-task` (medium/low) — Fire-and-forget Task in notification observer
- `Sources/TerminalController.swift:686` `unchecked-sendable-race` (high/medium) — SocketFastPathState @unchecked Sendable with queue.sync blocking
- `Sources/TerminalController.swift:1916` `unstructured-task` (medium/medium) — Fire-and-forget Task for path monitor restart
- `Sources/TerminalController.swift:2327` `semaphore-block` (critical/high) — DispatchSemaphore blocking socket worker thread on async auth operations
- `Sources/TerminalController.swift:2643` `async-after-timing` (medium/medium) — DispatchQueue.asyncAfter for listener rearm scheduling (timing hack)
- `Sources/TerminalController.swift:2667` `async-after-timing` (medium/low) — DispatchQueue.main.asyncAfter for listener restart scheduling
- `Sources/TerminalController.swift:5009` `dispatch-main` (critical/high) — DispatchQueue.main.sync in v2MainSync creates deadlock risk
- `Sources/TerminalController.swift:5034` `semaphore-block` (critical/high) — DispatchSemaphore blocking socket worker on v2VmCall async bridge
- `Sources/TerminalController.swift:7261` `dispatch-main` (medium/low) — DispatchQueue.main.async for tabManager shell activity update (telemetry path)
- `Sources/TerminalController.swift:7280` `dispatch-main` (medium/low) — DispatchQueue.main.async for workspace sidebar sync
- `Sources/TerminalController.swift:10623` `dispatch-main` (medium/low) — DispatchQueue.main.async in v2FeedbackOpen (low-risk but avoidable)
- `Sources/TerminalController.swift:10678` `dispatch-main` (medium/low) — DispatchQueue.main.async in v2SettingsOpen (low-risk but avoidable)
- `Sources/TerminalController.swift:10700` `semaphore-block` (critical/medium) — DispatchSemaphore blocking on feedback submission async bridge
- `Sources/TerminalController.swift:10834` `unstructured-task` (medium/low) — Fire-and-forget Task in feed event handler
- `Sources/TerminalController.swift:11127` `dispatch-main` (medium/low) — DispatchQueue.main.async for browser JavaScript evaluation (weaker than @MainActor)
- `Sources/TerminalController.swift:11203` `semaphore-block` (critical/medium) — DispatchSemaphore + NSLock blocking on async browser download condition
- `Sources/TerminalController.swift:14003` `semaphore-block` (high/medium) — DispatchSemaphore + NSLock blocking on file system watcher setup
- `Sources/TerminalController.swift:14045` `semaphore-block` (high/medium) — DispatchSemaphore + NSLock blocking on notification-based download event
- `Sources/TerminalController.swift:17732` `manual-lock` (medium/low) — NSLock for panel snapshot state should be actor or atomic-like wrapper
- `Sources/TerminalController.swift:18624` `dispatch-main` (high/low) — DispatchQueue.main.sync for NSWorkspace.open deadlock risk
- `Sources/TerminalController.swift:18811` `dispatch-main` (medium/low) — DispatchQueue.main.async for webView focus reassertion

### `Sources/TerminalNotificationCallerResolver.swift` (1 findings, deferred)

- `Sources/TerminalNotificationCallerResolver.swift:179` `dispatch-main` (high/high) — Dangerous DispatchQueue.main.sync deadlock risk in runOnMain helper

### `Sources/TerminalSSHSessionDetector.swift` (2 findings, deferred)

- `Sources/TerminalSSHSessionDetector.swift:17` `completion-handler` (medium/high) — completion-handler API for async file upload operation
- `Sources/TerminalSSHSessionDetector.swift:283` `semaphore-block` (high/high) — DispatchSemaphore blocking on async process completion

### `Sources/TerminalWindowPortal.swift` (3 findings, deferred)

- `Sources/TerminalWindowPortal.swift:771` `dispatch-main` (medium/medium) — DispatchQueue.main.async in @MainActor method scheduleExternalGeometrySynchronize
- `Sources/TerminalWindowPortal.swift:1305` `dispatch-main` (medium/low) — DispatchQueue.main.async in @MainActor method scheduleDeferredFullSynchronizeAll
- `Sources/TerminalWindowPortal.swift:2094` `dispatch-main` (medium/medium) — DispatchQueue.main.async in @MainActor static method scheduleExternalGeometrySynchronizeForAllWindows

### `Sources/Update/MinimalModeSidebarControls.swift` (1 findings, deferred)

- `Sources/Update/MinimalModeSidebarControls.swift:259` `combine` (medium/medium) — Combine @Published observation with DispatchQueue.main.receive() replaceable by async/await or Task

### `Sources/Update/UpdatePopoverView.swift` (1 findings, deferred)

- `Sources/Update/UpdatePopoverView.swift:10` `completion-handler` (medium/medium) — Convert dismiss completion handler to async/await or remove if not needed

### `Sources/WindowToolbarController.swift` (1 findings, deferred)

- `Sources/WindowToolbarController.swift:93` `dispatch-main` (medium/low) — DispatchQueue.main.async inside @MainActor method

### `Sources/Workspace.swift` (13 findings, deferred)

- `Sources/Workspace.swift:5` `combine` (medium/high) — Combine import and sink/CombineLatest usage replaceable by async/await
- `Sources/Workspace.swift:39` `unchecked-sendable-race` (medium/low) — WorkspacePendingTerminalInputObserver @unchecked Sendable with mutable state
- `Sources/Workspace.swift:1796` `async-after-timing` (medium/low) — asyncAfter timing hack for terminal surface readiness timeout
- `Sources/Workspace.swift:2013` `manual-lock` (medium/low) — NSLock protecting mutable state in WebSocketDelegate
- `Sources/Workspace.swift:2675` `semaphore-block` (high/high) — Semaphore.wait() blocks RPC write path on completion handler response
- `Sources/Workspace.swift:4427` `async-after-timing` (medium/low) — asyncAfter retry delay for proxy broker stream restart
- `Sources/Workspace.swift:4868` `manual-lock` (medium/medium) — NSLock protecting port readiness state in RemoteProxyBroker startup
- `Sources/Workspace.swift:5523` `manual-lock` (medium/medium) — NSLock protecting port readiness in RemotePTYBridgeServer startup
- `Sources/Workspace.swift:5914` `manual-lock` (medium/medium) — NSLock protecting PTY bridge start result in waitForPTYBridgeStart
- `Sources/Workspace.swift:6100` `manual-lock` (medium/medium) — NSLock protecting result in runOnControllerQueue synchronization
- `Sources/Workspace.swift:6133` `completion-handler` (medium/medium) — uploadDroppedFiles completion handler convertible to async
- `Sources/Workspace.swift:7010` `semaphore-block` (high/medium) — DispatchGroup.wait() blocks synchronous runProcess() function
- `Sources/Workspace.swift:15404` `async-after-timing` (medium/low) — asyncAfter hardcoded 2-second timeout for layout follow-up

### `Sources/cmuxApp.swift` (11 findings, deferred)

- `Sources/cmuxApp.swift:753` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async for AppKit modal defer with @MainActor or on-next-runloop callback
- `Sources/cmuxApp.swift:1173` `unstructured-task` (medium/low) — Store or track Task handle for window close operation or use structured concurrency
- `Sources/cmuxApp.swift:2283` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async for BrowserDataImportCoordinator with direct call or @MainActor context
- `Sources/cmuxApp.swift:4398` `manual-lock` (medium/low) — Replace NSLock in AppIconLaunchState with actor or atomic reference type
- `Sources/cmuxApp.swift:5055` `dispatch-main` (medium/medium) — Replace DispatchQueue.global async-to-main pattern with async/await and Task concurrency
- `Sources/cmuxApp.swift:5165` `manual-lock` (high/medium) — Replace NSLock in CmuxUITestCapture.nextSequence with atomic or actor
- `Sources/cmuxApp.swift:6028` `dispatch-main` (medium/medium) — Replace nested DispatchQueue.global/main pattern in NotificationSound preparation with async/await
- `Sources/cmuxApp.swift:6070` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async for ScrollViewReader scroll in settings navigation with explicit @MainActor context
- `Sources/cmuxApp.swift:6246` `async-after-timing` (medium/low) — Replace asyncAfter timing hack with structured concurrency
- `Sources/cmuxApp.swift:7627` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async for presentImportDialog with direct @MainActor call
- `Sources/cmuxApp.swift:8240` `dispatch-main` (medium/low) — Replace DispatchQueue.main.async single-line state update with direct @MainActor assignment

---

## Scan gap

One scan group (`CmuxEventBus.swift`, `ClosedItemHistory.swift`, `Panels/BrowserScreenshot.swift`, `TerminalNotificationQueue.swift`) did not return structured output during the parallel scan. `CmuxEventBus` was reviewed manually and its lock+semaphore design is sound (all mutable state guarded by `NSLock`); the other three are unscanned and are a follow-up. None are in this PR's fix scope.

---

## Post-review status (after CI + Greptile/CodeRabbit)

The applied fix set was narrowed from 15 files to 11 after CI and bot review caught
issues the per-file adversarial pass missed:

- **Reverted / deferred (added to follow-ups):**
  - `Sources/Update/UpdateDriver.swift` and the reattach loops in `Sources/CmuxConfig.swift`
    introduced `Task.sleep`, which the `cmux-swift-blocking-runtime` rule flags the same as
    `asyncAfter` (lateral, not a real fix). Same reason `Update/UpdateController.swift` was
    already deferred. A continuation-based `DispatchSourceTimer` (UpdateDriver) and a
    parent-directory `DispatchSourceFileSystemObject` watch (CmuxConfig reattach) are the
    sleep-free fixes for a future PR.
  - `Sources/App/CmuxCLIPathInstaller.swift`: the patch replaced concurrent pipe draining with a
    sequential stdout-then-stderr drain, which can deadlock on a child that fills the stderr pipe
    buffer (>64KB). Reverted; the only safe change there is `NSLock` -> `OSAllocatedUnfairLock` on
    the output buffer while keeping concurrent draining.
  - `Sources/WindowDragHandleView.swift`: marking the breadcrumb-limiter `@MainActor` rippled
    isolation warnings onto `NSApp.currentEvent` default arguments (evaluated in a nonisolated
    default-arg context). Marginal finding; reverted.

- **Fixed in place after review:**
  - `Sources/TerminalImageTransfer.swift` (CodeRabbit Critical): kept `@unchecked Sendable` (the
    honest annotation for a non-Sendable cancellation closure) with the `OSAllocatedUnfairLock`
    modernization, instead of a plain `Sendable` + unchecked wrapper that falsely implied the
    closure was cross-executor safe.
  - `Sources/TerminalNotificationStore.swift` (CodeRabbit Major): replaced a fire-and-forget
    `defer { Task { finish } }` with an inline `await finish` after the continuation so a
    follow-up request for the same path is not dropped during the race window.

**Final applied set (11 files):** ShortcutRoutingSupport, AuthManager,
BackgroundWorkspacePrimeCoordinator, FileExplorerStore, FilePreviewPanel, SessionIndexStore,
SocketControlSettings, TerminalImageTransfer, TerminalNotificationPolicy, TerminalNotificationStore,
TextBoxInput.
