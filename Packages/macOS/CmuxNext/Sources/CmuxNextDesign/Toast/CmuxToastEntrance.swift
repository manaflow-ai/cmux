/// How a toast arrives and leaves (``CmuxToastMotion``). Every entrance fades; Reduce Motion keeps only the fade.
public nonisolated enum CmuxToastEntrance: String, Sendable, Hashable {
    /// It rises from the window's bottom edge (the toasts' motion since cx-f6i7) and fades out in place.
    case rise
    /// It grows from 95% of its size about its center, and shrinks a little as it fades out.
    case pop
    /// It slides in from the window's trailing edge, and back toward it as it fades out.
    case slide
}
