/// A benchmark workload: a fidelity-corpus case or a generated redraw pattern.
public enum TerminalWorkload: Hashable, Sendable {
    /// A case of `schemas/terminal-corpus` by name (`shell-prompt`, `alt-screen-editor`, ...).
    case corpus(String)
    /// Plain output as fast as the source delivers it (a `cat` of a large log).
    case flood(bytes: Int)
    /// Full-screen cursor-addressed redraws, one per frame (a process monitor).
    case htop(frames: Int)
    /// An editor in the alternate screen scrolling a region, one line per frame.
    case vim(frames: Int)

    /// The generated workloads at their default sizes.
    public static let generatedDefaults: [TerminalWorkload] = [
        .flood(bytes: 8 * 1024 * 1024), .htop(frames: 600), .vim(frames: 600),
    ]

    /// `flood`, `htop`, `vim` or `corpus:<name>` (the `CMUX_IOS_TERMINAL_BENCH` value).
    public var id: String {
        switch self {
        case .corpus(let name): "corpus:" + name
        case .flood: "flood"
        case .htop: "htop"
        case .vim: "vim"
        }
    }

    /// Parses `id`; generated workloads take their default sizes.
    public init?(id: String) {
        if id.hasPrefix("corpus:") {
            let name = String(id.dropFirst("corpus:".count))
            guard !name.isEmpty else { return nil }
            self = .corpus(name)
            return
        }
        guard let match = Self.generatedDefaults.first(where: { $0.id == id }) else { return nil }
        self = match
    }
}
