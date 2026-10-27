#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
public import CmuxNextInput
import CmuxNextCompat
import Foundation
import ObjectiveC
import QuartzCore

/// `debug.input` action `dirty`: the views an input turn marks dirty, and which of them lie outside
/// the event's target (plans/cmux-next/chrome-parity/p04-input.md, task 093; machine queue
/// MQ-input-dirty-views). A key typed into one field should dirty that field's subtree only; a
/// sidebar, a toolbar or another window redrawn in the same turn is work the key did not ask for.
///
/// The first `dirty` request installs the recorder; `reset` removes it. While installed it replaces
/// `-[NSView setNeedsDisplay:]`, `-setNeedsDisplayInRect:`, `-setNeedsLayout:`,
/// `-setNeedsUpdateConstraints:` and `-[CALayer setNeedsLayout]`, `-setNeedsDisplay`,
/// `-setNeedsDisplayInRect:`, and subscribes to the input tap. An input turn starts at a key down, a
/// button or a scroll event and ends after the main run loop's commit pass (AppKit's display cycle
/// and the Core Animation commit), which it times. Each dirty call in a turn (the outermost hooked
/// call, on the main thread) counts under its site: the call, the receiver's class, its relation to
/// the target (the key's first responder, the hit view of a pointer event) and its stack, at most
/// ``InputDirtyLedger/defaultSiteLimit`` sites. The read resolves the stacks off the main thread.
///
/// Chrome records the same thing on request: raster invalidation tracking keeps each invalidated
/// client, rect and reason while DevTools' paint flashing is on
/// (`third_party/blink/renderer/platform/graphics/paint/raster_invalidation_tracking.h`), and its
/// layout tree logs the objects a frame lays out (`LocalFrameView::UpdateStyleAndLayout`).
///
/// ```swift
/// let dirty = InputDirtyRecorder(tap: inputTap) { copy in await mainWork.apply(.automation, owner: "debug.input.dirty") { copy() } }
/// router.register([DebugInput(sources: sources, recorders: [hops, dirty]).method])
/// ```
public nonisolated final class InputDirtyRecorder: DebugInputRecorder {
    /// Runs `copy` on the main thread and returns its result: the app posts it as classed main work.
    public typealias MainCopy = @Sendable (_ copy: @escaping @MainActor @Sendable () -> InputDirtyCopy) async -> InputDirtyCopy

    let ledger: InputDirtyLedger
    private let onMain: MainCopy

    /// - Parameters:
    ///   - tap: The app's one input tap: its events start the turns.
    ///   - onMain: Runs the request's main-thread part (install, copy, remove).
    @MainActor
    public convenience init(tap: InputEventTap, onMain: @escaping MainCopy) {
        self.init(ledger: InputDirtyLedger(tap: tap), onMain: onMain)
    }

    @MainActor
    init(ledger: InputDirtyLedger, onMain: @escaping MainCopy) {
        self.ledger = ledger
        self.onMain = onMain
    }

    public var kind: DebugInputRecorderKind { .dirty }

    /// Installs the recorder at the first request, then the sites since launch or since the last reset.
    public func rows(sinceLaunch: Bool) async -> DebugInputDirty {
        let copy = await onMain { [ledger] in ledger.request(sinceLaunch: sinceLaunch) }
        return await Self.resolve(copy)
    }

    /// Removes the hooks, the tap subscription and the run-loop observers; the since-reset sites start over.
    public func reset() async {
        _ = await onMain { [ledger] in ledger.remove() }
    }

    /// The reply, its stacks resolved with `dladdr` (dyld's lock): never on the main thread.
    @concurrent
    static func resolve(_ copy: InputDirtyCopy) async -> DebugInputDirty {
        DebugInputDirty(copy)
    }
}

/// The main-thread part of ``InputDirtyRecorder``: the hooks, the current turn and the sites.
@MainActor
final class InputDirtyLedger {
    static let defaultSiteLimit = 256
    /// The newest turns whose commit pass and call count the distributions keep.
    static let defaultTurnLimit = 256
    /// Return addresses kept per site.
    static let stackDepth = 32
    /// Return addresses that tell two sites of one call, class and relation apart.
    static let siteDepth = 16
    /// Superlayers walked to find a layer's view.
    static let layerWalkLimit = 64

    /// One input turn: from its first event to the end of the commit pass after it.
    private struct Turn {
        var kind: InputDirtyTurnKind
        var target: NSView?
        var passStart: UInt64?
        var calls = 0
        var offTarget = 0
    }

    private let tap: InputEventTap
    private let siteLimit: Int
    private let turnLimit: Int
    private let now: @MainActor () -> UInt64
    private var hooks: [InputDirtyHook] = []
    private var subscription: InputSubscription?
    private var observers: [MainRunLoopObserver] = []
    private(set) var isInstalled = false
    private var turn: Turn?
    /// Hooked calls running now: a call inside another (`setNeedsDisplay:` sending
    /// `setNeedsDisplayInRect:`) is the outer one's work.
    private var nesting = 0
    private var sinceLaunch = InputDirtyWindow()
    private var sinceReset = InputDirtyWindow()

    /// - Parameters:
    ///   - tap: The input tap whose events start the turns.
    ///   - siteLimit: The most sites each window keeps.
    ///   - turnLimit: The most turns the distributions keep.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (tests: a fake).
    init(tap: InputEventTap, siteLimit: Int = InputDirtyLedger.defaultSiteLimit, turnLimit: Int = InputDirtyLedger.defaultTurnLimit,
         now: @escaping @MainActor () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.tap = tap
        self.siteLimit = max(1, siteLimit)
        self.turnLimit = max(1, turnLimit)
        self.now = now
    }

    // MARK: Requests

    /// Installs the recorder when it is not installed, and copies one window's sites.
    func request(sinceLaunch launch: Bool) -> InputDirtyCopy {
        let installedNow = !isInstalled
        if installedNow { install() }
        return InputDirtyCopy(installed: true, installedNow: installedNow, sinceLaunch: launch,
                              window: launch ? sinceLaunch : sinceReset, siteLimit: siteLimit, turnLimit: turnLimit)
    }

    /// Removes what ``request(sinceLaunch:)`` installed and starts the since-reset window over.
    func remove() -> InputDirtyCopy {
        if isInstalled {
            // A swizzler that replaced a hook after it keeps its own: the hook passes calls through once removed.
            for hook in hooks where unsafe method_getImplementation(hook.method) == hook.replacement {
                unsafe method_setImplementation(hook.method, hook.original)
            }
            hooks = []
            subscription?.cancel()
            subscription = nil
            for observer in observers { observer.invalidate() }
            observers = []
            turn = nil
            isInstalled = false
        }
        sinceReset = InputDirtyWindow()
        return InputDirtyCopy(installed: false, installedNow: false, sinceLaunch: false, window: sinceReset,
                              siteLimit: siteLimit, turnLimit: turnLimit)
    }

    private func install() {
        hooks = InputDirtyCall.allCases.compactMap { InputDirtyHook(call: $0, ledger: self) }
        for hook in hooks { unsafe method_setImplementation(hook.method, hook.replacement) }
        subscription = tap.subscribe(class: [.key, .button, .scroll], handler: { [weak self] event in self?.dispatched(event) })
        let pass: CFRunLoopActivity = [.beforeWaiting, .exit]
        observers = [
            MainRunLoopObserver(activities: pass, order: CFIndex.min) { [weak self] _ in self?.passBegan() },
            MainRunLoopObserver(activities: pass, order: MainRunLoopObserver.lastOrder) { [weak self] _ in self?.passEnded() },
        ]
        isInstalled = true
    }

    // MARK: Turns

    private func dispatched(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            began(.key, target: Self.keyTarget(in: event.window))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            began(.click, target: Self.pointerTarget(of: event))
        case .scrollWheel:
            began(.scroll, target: Self.pointerTarget(of: event))
        default:
            break
        }
    }

    /// An input event is dispatched: a turn starts, or the turn in progress takes its target.
    func began(_ kind: InputDirtyTurnKind, target: NSView?) {
        guard isInstalled else { return }
        if turn == nil { turn = Turn(kind: kind) }
        turn?.target = target
    }

    /// The first observer of a commit pass ran (tests call it directly).
    func passBegan() {
        guard turn != nil else { return }
        turn?.passStart = now()
    }

    /// The last observer of a commit pass ran: the turn ends with the pass's time (tests call it directly).
    func passEnded() {
        guard let current = turn, let start = current.passStart else { return }
        let end = now()
        let pass = InputDirtyWindow.Pass(kind: current.kind, nanos: end >= start ? end - start : 0, calls: current.calls,
                                         offTarget: current.offTarget)
        sinceLaunch.end(pass, limit: turnLimit)
        sinceReset.end(pass, limit: turnLimit)
        turn = nil
    }

    /// The view a key goes to: the first responder, or the control a field editor edits.
    static func keyTarget(in window: NSWindow?) -> NSView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView { return control }
        return responder
    }

    /// The view under a pointer event.
    static func pointerTarget(of event: NSEvent) -> NSView? {
        guard let content = event.window?.contentView else { return nil }
        let root = content.superview ?? content
        return root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    }

    // MARK: Dirty calls

    /// Runs `send`, a hooked call's original, recording the call first when `records` (a call that
    /// dirties) and it is the outermost hooked call on the main thread in an input turn. Any thread: a
    /// call off the main thread only passes.
    nonisolated func around(_ call: InputDirtyCall, _ receiver: AnyObject, records: Bool, _ send: () -> Void) {
        guard Thread.isMainThread else { return send() }
        MainActor.assumeIsolated { record(call, receiver, records: records, send) } // main-proof: Thread.isMainThread checked above
    }

    private func record(_ call: InputDirtyCall, _ receiver: AnyObject, records: Bool, _ send: () -> Void) {
        if records, nesting == 0, isInstalled, let current = turn { note(call, receiver, target: current.target, kind: current.kind) }
        nesting += 1
        defer { nesting -= 1 }
        send()
    }

    private func note(_ call: InputDirtyCall, _ receiver: AnyObject, target: NSView?, kind: InputDirtyTurnKind) {
        let view = Self.hostingView(of: receiver)
        let relation = InputDirtyRelation(of: view, to: target)
        let stack = Thread.callStackReturnAddresses.prefix(Self.stackDepth).map(\.uintValue)
        var hasher = Hasher()
        for address in stack.prefix(Self.siteDepth) { hasher.combine(address) }
        let receiverClass: AnyObject.Type = type(of: receiver)
        let key = InputDirtyWindow.Key(call: call, receiverClass: ObjectIdentifier(receiverClass), relation: relation,
                                       stack: hasher.finalize())
        let site = {
            InputDirtyWindow.Site(call: call, objectClass: String(describing: receiverClass),
                                  viewClass: view.map { String(describing: type(of: $0)) }, relation: relation, stack: stack)
        }
        sinceLaunch.add(key, kind: kind, limit: siteLimit, new: site)
        sinceReset.add(key, kind: kind, limit: siteLimit, new: site)
        turn?.calls += 1
        if relation.isOffTarget { turn?.offTarget += 1 }
    }

    /// The view `receiver` draws for: itself, or the delegate of the nearest layer up its layer tree.
    static func hostingView(of receiver: AnyObject) -> NSView? {
        if let view = receiver as? NSView { return view }
        var layer = receiver as? CALayer
        var steps = 0
        while let current = layer, steps < layerWalkLimit {
            if let view = current.delegate as? NSView { return view }
            layer = current.superlayer
            steps += 1
        }
        return nil
    }
}
#endif
