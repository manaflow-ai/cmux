import CmuxSwiftRender

/// A lexical scope for live evaluation: frozen locals (loop variables, `let`
/// bindings) chained to a parent, with the root falling through to the
/// instance's ``LiveStateStore``.
///
/// Locals are plain `SwiftValue`s frozen at the time the enclosing structure
/// evaluated (a ForEach row's element, a `let`). State names are *not*
/// copied in: they resolve through ``resolve(_:)`` to a ``StateBox`` read at
/// lookup time, which is what registers the Observation dependency on the
/// caller's surrounding tracking scope (a SwiftUI body).
public final class LiveScope {
    public let store: LiveStateStore
    private var locals: [String: SwiftValue]
    private var provenances: [String: LiveBindingProvenance]
    private let parent: LiveScope?

    public init(store: LiveStateStore, locals: [String: SwiftValue] = [:], parent: LiveScope? = nil) {
        self.store = store
        self.locals = locals
        self.provenances = [:]
        self.parent = parent
    }

    /// Resolves `name`: locals, then parent scopes, then (lazily, observably)
    /// the state store.
    public func resolve(_ name: String) -> SwiftValue? {
        if let local = locals[name] { return local }
        if let inherited = parent?.resolve(name) { return inherited }
        return store.box(name)?.value
    }

    /// Defines or overwrites a frozen local in this scope.
    public func define(_ name: String, _ value: SwiftValue) {
        locals[name] = value
    }

    /// The state box for `name`, ignoring locals (locals are immutable
    /// snapshots; only state is assignable).
    public func stateBox(_ name: String) -> StateBox? {
        store.box(name)
    }

    /// Records binding provenance for a projected loop variable (`$row`).
    public func defineProvenance(_ name: String, _ provenance: LiveBindingProvenance) {
        provenances[name] = provenance
    }

    /// Binding provenance for `name`, walking up the scope chain.
    public func provenance(_ name: String) -> LiveBindingProvenance? {
        provenances[name] ?? parent?.provenance(name)
    }

    /// A child scope for a loop body, branch, or row closure.
    public func child(locals: [String: SwiftValue] = [:]) -> LiveScope {
        LiveScope(store: store, locals: locals, parent: self)
    }
}

/// Where a projected loop binding (`$row`) points: the backing collection box
/// plus the row's identity, so bindings written through it follow the row by
/// identity across reorders instead of by position.
public struct LiveBindingProvenance: Sendable {
    public let box: StateBox
    /// Identity field name from `id: \.field`, or nil when identity is the
    /// element value itself (`id: \.self`).
    public let idField: String?
    public let idValue: SwiftValue

    public init(box: StateBox, idField: String?, idValue: SwiftValue) {
        self.box = box
        self.idField = idField
        self.idValue = idValue
    }
}
