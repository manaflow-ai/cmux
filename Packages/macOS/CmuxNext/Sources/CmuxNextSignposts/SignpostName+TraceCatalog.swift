public import CmuxNextTrace

/// The fixed name-table entries every Release trace ring of this process starts with (plans/cmux-next/trace.md,
/// "Name table"): each ``SignpostName`` at its fixed id, then one entry per ``SignpostCategory``. The ring's
/// creator passes this list to `TraceRing(sizes:identity:catalog:)`, so a ring holds the text of every id its
/// records use and a later build, whose catalog has more names, decodes it from the ring alone. Perfetto
/// writes its interned names into each buffer for the same reason
/// (`include/perfetto/tracing/track_event_interned_data_index.h`).
///
/// ```swift
/// let ring = TraceRing(sizes: sizes, identity: identity, catalog: SignpostName.traceCatalog)
/// ```
nonisolated extension SignpostName {
    /// The catalog and category entries, in id order. Built on each read: a ring's creator reads it once,
    /// before the ring takes records.
    public static var traceCatalog: [TraceRing.CatalogName] {
        TraceRing.nameTable(
            names: allCases.map { (id: $0.rawValue, category: $0.traceCategory.traceBit, text: $0.staticName) },
            categories: SignpostCategory.allCases.map { (bit: $0.traceBit, text: $0.traceName) }
        )
    }
}

nonisolated extension SignpostCategory {
    /// The category's name as a ring's category entry holds it: ``rawValue`` as a compile-time string, which
    /// the ring's name table takes so that no run-time text can become a name.
    public var traceName: StaticString {
        switch self {
        case .action: "action"
        case .motion: "motion"
        case .key: "key"
        case .switch: "switch"
        case .create: "create"
        case .cef: "cef"
        case .launch: "launch"
        case .stall: "stall"
        case .burst: "burst"
        case .daemon: "daemon"
        case .frame: "frame"
        case .task: "task"
        case .hang: "hang"
        case .input: "input"
        case .webview: "webview"
        case .remote: "remote"
        case .crash: "crash"
        case .control: "control"
        case .ghostty: "ghostty"
        case .resize: "resize"
        case .webui: "webui"
        case .log: "log"
        }
    }
}
