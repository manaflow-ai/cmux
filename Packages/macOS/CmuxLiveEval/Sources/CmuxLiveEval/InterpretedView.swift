import SwiftUI

/// The compiled stub view hosting an interpreted program.
///
/// This is the live-eval mechanism end to end: a compiled SwiftUI view whose
/// `body` re-walks an interpreted AST against `@Observable` state boxes. The
/// boxes live in a ``LiveStateStore`` held in compiled `@State`, so SwiftUI
/// owns the storage lifetime exactly as it would for a compiled view's
/// `@State`. Every nesting level of the AST renders inside its own stub view
/// (``LiveStatementView``), so Observation invalidates the smallest stub that
/// read a mutated box rather than the whole tree.
public struct InterpretedView: View {
    let engine: LiveEvalEngine
    @State private var store: LiveStateStore

    @MainActor
    public init(engine: LiveEvalEngine) {
        self.engine = engine
        _store = State(initialValue: engine.makeStore())
    }

    /// Test/demo hook: host with an externally owned store so the driver can
    /// mutate boxes directly.
    @MainActor
    public init(engine: LiveEvalEngine, store: LiveStateStore) {
        self.engine = engine
        _store = State(initialValue: store)
    }

    public var body: some View {
        let _ = engine.traceBody(Self.self)
        LiveNodeView(engine: engine, node: engine.evaluateRoot(LiveScope(store: store)))
    }
}

/// Renders one shallow ``LiveNode`` as real SwiftUI.
///
/// Deliberately erases through `AnyView`: proving that Observation dependency
/// registration survives AnyView erasure is a spike question, so the erasure
/// sits exactly where a production engine would need it (heterogeneous node
/// kinds from one switch).
struct LiveNodeView: View {
    let engine: LiveEvalEngine
    let node: LiveNode

    var body: some View {
        let _ = engine.traceBody(Self.self)
        erased
    }

    private var erased: AnyView {
        switch node {
        case let .text(string):
            return AnyView(Text(string))
        case let .button(title, action):
            return AnyView(Button(title) { action() })
        case let .textField(placeholder, text):
            return AnyView(TextField(placeholder, text: text))
        case let .toggle(title, isOn):
            return AnyView(Toggle(title, isOn: isOn))
        case let .stack(axis, spacing, content):
            let spacingValue = spacing.map { CGFloat($0) }
            switch axis {
            case .vertical:
                return AnyView(VStack(alignment: .leading, spacing: spacingValue) {
                    LiveBlockView(engine: engine, block: content)
                })
            case .horizontal:
                return AnyView(HStack(spacing: spacingValue) {
                    LiveBlockView(engine: engine, block: content)
                })
            case .depth:
                return AnyView(ZStack {
                    LiveBlockView(engine: engine, block: content)
                })
            }
        case let .forEach(rows):
            return AnyView(ForEach(rows) { row in
                LiveBlockView(engine: engine, block: row.content)
            })
        case .spacer:
            return AnyView(Spacer())
        case .divider:
            return AnyView(Divider())
        case .empty:
            return AnyView(EmptyView())
        }
    }
}

/// Expands an unevaluated block into per-statement stub views.
///
/// Expansion evaluates only `let` bindings; renderable statements stay
/// unevaluated until each ``LiveStatementView``'s own body runs, which is
/// what scopes Observation registration per statement.
struct LiveBlockView: View {
    let engine: LiveEvalEngine
    let block: LiveBlock

    var body: some View {
        let _ = engine.traceBody(Self.self)
        ForEach(engine.expandBlock(block)) { entry in
            LiveStatementView(engine: engine, entry: entry)
                .equatable()
        }
    }
}

/// One interpreted statement's compiled stub.
///
/// The body performs the (Observation-tracked) evaluation of exactly one
/// statement subtree, so the box reads inside it register to this stub and a
/// later mutation invalidates only this stub's body. Equatable so parent
/// re-renders skip statements whose AST node and scope are unchanged;
/// Observation-driven invalidation bypasses the equality gate by design.
struct LiveStatementView: View, Equatable {
    let engine: LiveEvalEngine
    let entry: LiveBlockEntry

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI performs view diffing on the main actor; Equatable's
        // requirement is just spelled nonisolated.
        MainActor.assumeIsolated {
            lhs.engine === rhs.engine
                && lhs.entry.id == rhs.entry.id
                && lhs.entry.statement.id == rhs.entry.statement.id
                && lhs.entry.scope === rhs.entry.scope
        }
    }

    var body: some View {
        let _ = engine.traceBody(Self.self)
        let nodes = engine.evaluateStatement(entry.statement, entry.scope)
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            LiveNodeView(engine: engine, node: node)
        }
    }
}
