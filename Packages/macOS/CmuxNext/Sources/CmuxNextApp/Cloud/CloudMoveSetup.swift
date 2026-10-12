import Foundation

/// What Move to Cloud (``CloudMove``) runs and where it puts a folder on a
/// Cloud machine. ``CloudService`` holds the app's; tests point it at stand-ins.
struct CloudMoveSetup {
    /// The `cmux` binary (the bundled cmux-tui) that runs `cmux link sync push`
    /// and `cmux link agent move`; nil when this build has none.
    var cli: URL?
    /// The folders a synced folder goes under on a machine, tried in order: the
    /// image's work user's `~/work`, then root's on machines baked before that
    /// user existed (cmux-host `daemon_spec.rs`, `WORK_HOME` and `ROOT_HOME`).
    /// The machine daemon takes a moved chat only under its `$HOME/work`.
    var workRoots: [String] = ["/home/cmux/work", "/root/work"]
    /// How long one CLI run may take: a first sync of a big repository, or a long chat, can take minutes.
    var timeout: Duration = .seconds(30 * 60)
}
