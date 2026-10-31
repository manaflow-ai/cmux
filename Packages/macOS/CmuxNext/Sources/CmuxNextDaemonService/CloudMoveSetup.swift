public import Foundation

/// What Move to Cloud (``CloudMove``) and Bring Back Local (``CloudBringBack``) run, and where
/// a folder goes on a Cloud machine. ``CloudService`` holds the app's; tests point it at stand-ins.
public struct CloudMoveSetup {
    /// The `cmux` binary (the bundled cmux-tui) that runs `cmux link sync push`
    /// and `cmux link agent move`; nil when this build has none.
    public var cli: URL?
    /// The folders a synced folder goes under on a machine, tried in order: the
    /// image's work user's `~/work`, then root's on machines baked before that
    /// user existed (cmux-host `daemon_spec.rs`, `WORK_HOME` and `ROOT_HOME`).
    /// The machine daemon takes a moved chat only under its `$HOME/work`.
    public var workRoots: [String] = ["/home/cmux/work", "/root/work"]
    /// How long one CLI run may take: a first sync of a big repository, or a long chat, can take minutes.
    public var timeout: Duration = .seconds(30 * 60)
    /// Where the moved chats are kept for Bring Back Local (``CloudMovedChats``): the app's own
    /// defaults; nil keeps them in memory.
    public var ledger: UserDefaults?
    /// How often a moved chat's file requests are triaged (``CloudAccessAsks``), one run at a time.
    public var accessPoll: Duration = .seconds(3)
    /// How often a machine's granted folders are copied again (`cmux link access sync`).
    public var accessSync: Duration = .seconds(60)

    public init(cli: URL? = nil, workRoots: [String] = ["/home/cmux/work", "/root/work"], timeout: Duration = .seconds(30 * 60),
                ledger: UserDefaults? = nil, accessPoll: Duration = .seconds(3), accessSync: Duration = .seconds(60)) {
        (self.cli, self.workRoots, self.timeout, self.ledger, self.accessPoll, self.accessSync) = (cli, workRoots, timeout, ledger, accessPoll, accessSync)
    }
}
