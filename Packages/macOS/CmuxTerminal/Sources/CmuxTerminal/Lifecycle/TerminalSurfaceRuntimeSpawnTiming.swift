/// When a terminal surface should enter its native Ghostty runtime.
enum TerminalSurfaceRuntimeSpawnTiming: Equatable, Sendable {
    case immediate
    case pacedSessionRestore
}
