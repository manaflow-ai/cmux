/// Which kind of action the custom toolbar editor is composing.
enum CustomToolbarActionDraftMode: Hashable, CaseIterable {
    /// A literal command/snippet, optionally Return-terminated.
    case text
    /// An ordered sequence of key combos and/or text snippets: a macro.
    case keySequence
}
