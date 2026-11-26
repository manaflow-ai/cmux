/// Parser state for ``RemoteTmuxScreenTitleFilter``.
enum RemoteTmuxScreenTitleFilterState {
    case text        // normal passthrough
    case esc         // saw ESC, holding it until we know if it's `ESC k`
    case title       // inside `ESC k ...`, dropping the title bytes
    case titleEsc    // inside the title, saw ESC; maybe the `ESC \` terminator
}
