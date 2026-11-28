public import AppKit

/// The single owner of every open cmux dialog. Callers present a spec in a
/// scope and get exactly one answer; automation (the debug socket, the
/// browser automation broker) reads and answers dialogs here, through the
/// same path a click takes. Dialogs in one scope show one at a time, in
/// order (`CmuxDialogQueue`).
@MainActor
public final class CmuxDialogCenter {
    public static let shared = CmuxDialogCenter()

    /// One open dialog, as automation sees it.
    public struct Record: Equatable, Sendable {
        public var id: Int
        public var spec: CmuxDialogSpec
        public var scope: String
        public var visible: Bool
        public var values: [String: CmuxDialogValue]
    }

    public enum Event: Equatable, Sendable {
        case opened(Record)
        case answered(id: Int, answer: CmuxDialogAnswer)
    }

    private struct Entry {
        var spec: CmuxDialogSpec
        /// Weak: the dialog never keeps its tab or window alive.
        var scope: CmuxDialogWeakScope
        var completion: (CmuxDialogAnswer) -> Void
        var view: CmuxDialogView?
        /// The tab view's deallocation marker (`CmuxDialogScopeLifetime`).
        var lifetime: UUID?
        /// The window's close observer.
        var closeObserver: (any NSObjectProtocol)?
    }

    private nonisolated enum ScopeKey: Hashable, Sendable {
        case object(ObjectIdentifier)
        case app
    }

    /// The host that places dialogs. Replaced by the R84 overlay host.
    public var host: any CmuxDialogHosting
    private var entries: [Int: Entry] = [:]
    private var queue = CmuxDialogQueue<ScopeKey>()
    private var nextID = 1
    private var observers: [UUID: (Event) -> Void] = [:]

    public init(host: any CmuxDialogHosting = CmuxDialogOverlayHost()) {
        self.host = host
    }

    // MARK: Presenting

    /// Shows `spec` in `scope` (after any dialog already open there) and
    /// calls `completion` once with the answer. Returns the dialog id.
    @discardableResult
    public func present(_ spec: CmuxDialogSpec, in scope: CmuxDialogScope,
                        completion: @escaping (CmuxDialogAnswer) -> Void) -> Int {
        let id = nextID
        nextID += 1
        let key = Self.key(scope)
        var entry = Entry(spec: spec, scope: CmuxDialogWeakScope(scope), completion: completion)
        // No dialog outlives its scope: a closed tab (or its pane or
        // workspace) or a closed window ends it with its cancel answer.
        if case .tab(let view) = scope {
            entry.lifetime = CmuxDialogScopeLifetime.attach(to: view) { [weak self] token in
                Task { @MainActor in self?.scopeEnded(token) }
            }
        }
        if let window = scope.window {
            entry.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in _ = self?.dismiss(id) }
            }
        }
        entries[id] = entry
        if queue.enqueue(id, in: key) { show(id) }
        if let record = record(id) { emit(.opened(record)) }
        return id
    }

    /// Shows `spec` in `scope` and waits for the answer.
    public func present(_ spec: CmuxDialogSpec, in scope: CmuxDialogScope) async -> CmuxDialogAnswer {
        await withCheckedContinuation { continuation in
            present(spec, in: scope) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Answering

    /// Presses button `button` of dialog `id` (visible or still queued),
    /// with the dialog's current field values. False when there is no such
    /// dialog or button.
    @discardableResult
    public func press(_ id: Int, button: String) -> Bool {
        guard let entry = entries[id], let pressed = entry.spec.buttons.first(where: { $0.id == button }) else { return false }
        finish(id, CmuxDialogAnswer(button: pressed.id, role: pressed.role, values: values(of: entry)))
        return true
    }

    /// Sets one field of dialog `id` (it must be visible).
    @discardableResult
    public func setValue(_ value: CmuxDialogValue, for field: String, in id: Int) -> Bool {
        entries[id]?.view?.setValue(value, for: field) ?? false
    }

    /// Runs one key against the visible dialog `id`, as if typed.
    @discardableResult
    public func key(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers = [], in id: Int) -> Bool {
        entries[id]?.view?.handle(key, modifiers: modifiers) ?? false
    }

    /// Ends dialog `id` as its cancel answer (tab closed, app quitting,
    /// the asking page navigated away).
    @discardableResult
    public func dismiss(_ id: Int) -> Bool {
        guard let entry = entries[id] else { return false }
        finish(id, .dismissed(entry.spec, values: values(of: entry)))
        return true
    }

    /// Ends every open dialog as its cancel answer (quit never waits on one).
    public func dismissAll() {
        for record in records.reversed() { dismiss(record.id) }
    }

    /// Ends every dialog shown in `view` (a tab) or `window`.
    public func dismissAll(in scope: CmuxDialogScope) {
        for id in queue.ids(in: Self.key(scope)).reversed() { dismiss(id) }
    }

    /// A tab view deallocated: end the dialogs scoped to it.
    private func scopeEnded(_ token: UUID) {
        for (id, entry) in entries where entry.lifetime == token { dismiss(id) }
    }

    // MARK: Reading

    /// Every open dialog, oldest first.
    public var records: [Record] { queue.order.compactMap { record($0.id) } }

    public func record(_ id: Int) -> Record? {
        guard let entry = entries[id] else { return nil }
        return Record(id: id, spec: entry.spec, scope: Self.kindName(entry.scope.kind), visible: queue.isVisible(id),
                      values: values(of: entry))
    }

    /// The visible dialog that blocks where `window` has the keyboard: one
    /// scoped to `window`, else one scoped to the tab view that holds the
    /// window's first responder, else, while the keyboard is in the window's
    /// chrome (the sidebar), one scoped to a tab inside `focusedArea` (the
    /// focused pane). A key that reaches `window` under the dialog's overlay
    /// (the overlay did not take the keyboard) is its key.
    public func dialogBlockingKeys(in window: NSWindow, focusedArea: NSView? = nil) -> Int? {
        let responder = window.firstResponder as? NSView
        func holds(_ area: NSView?, _ view: NSView) -> Bool {
            area.map { $0 === view || $0.isDescendant(of: view) } == true
        }
        return queue.order.first { item in
            guard queue.isVisible(item.id), let scope = entries[item.id]?.scope.live else { return false }
            switch scope {
            case .window(let scoped): return scoped === window
            case .tab(let view):
                guard view.window === window else { return false }
                return holds(responder, view) || focusedArea.map { view === $0 || view.isDescendant(of: $0) } == true
            case .app: return false
            }
        }?.id
    }

    /// The view of visible dialog `id` (screenshots, tests).
    public func view(_ id: Int) -> CmuxDialogView? { entries[id]?.view }

    /// Observes opens and answers; keep the token to stop.
    public func observe(_ observer: @escaping (Event) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func stopObserving(_ token: UUID) { observers[token] = nil }

    // MARK: Private

    private func show(_ id: Int) {
        guard let entry = entries[id] else { return }
        guard let scope = entry.scope.live else {
            dismiss(id)
            return
        }
        let view = CmuxDialogView(spec: entry.spec)
        view.onPress = { [weak self] button in self?.press(id, button: button) }
        entries[id]?.view = view
        host.show(view, in: scope) { [weak self] in self?.dismiss(id) }
    }

    private func finish(_ id: Int, _ answer: CmuxDialogAnswer) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let observer = entry.closeObserver { NotificationCenter.default.removeObserver(observer) }
        if let view = entry.view { host.hide(view) }
        let next = queue.remove(id)
        entry.completion(answer)
        emit(.answered(id: id, answer: answer))
        if let next { show(next) }
    }

    /// The visible view's values, else the spec's initial values.
    private func values(of entry: Entry) -> [String: CmuxDialogValue] {
        if let view = entry.view { return view.values }
        var values: [String: CmuxDialogValue] = [:]
        for field in entry.spec.fields {
            switch field {
            case .text(let id, _, let initial, _, _): values[id] = .text(initial)
            case .choice(let id, _, let options, let selected): values[id] = .text(selected ?? options.first?.value ?? "")
            case .check(let id, _, let on): values[id] = .bool(on)
            case .preview: break
            }
        }
        return values
    }

    private func emit(_ event: Event) {
        for observer in observers.values { observer(event) }
    }

    private static func kindName(_ kind: CmuxDialogWeakScope.Kind) -> String {
        switch kind {
        case .tab: "tab"
        case .window: "window"
        case .app: "app"
        }
    }

    private static func key(_ scope: CmuxDialogScope) -> ScopeKey {
        scope.key.map(ScopeKey.object) ?? .app
    }
}
