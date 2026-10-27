import Foundation

/// A machine whose daemon follows the app's build after an update (``DaemonUpdatePolicy``): an
/// acpmux ssh peer (``AcpmuxPeerUpdateTarget``), a Cloud machine. The policy decides when and in
/// which order; a target only says what it runs and updates itself when asked.
public nonisolated protocol DaemonUpdateTarget: Sendable {
    /// Stable across launches, unique among all targets (`acpmux-peer:huge-blue`, `cloud:<machine>`):
    /// the ledger and the board key it.
    var id: String { get }
    /// The machine as the person knows it, for the log and the notice.
    var displayName: String { get }
    /// The ssh host the sidebar shows this machine under (its tooltip shows the machine's update
    /// state), nil for a target that is not an ssh machine.
    var sshHost: String? { get }
    /// The build the target runs now (`<hash>[+dirty.x] [date]` or a commit); nil when unknown or
    /// unreachable: the policy then leaves it alone.
    func currentBuild() async -> String?
    /// Brings the target to `build`. Without `whileBusy`, only while it is idle: it does not
    /// interrupt a turn, a waiting permission or a sub-session's turn; it answers
    /// ``DaemonUpdateOutcome/busy`` and changes nothing. With `whileBusy` it updates mid-turn too:
    /// the restarted daemon resumes what it interrupted. The policy asks so from the first ask
    /// (``DaemonUpdatePolicy/Dependencies/updateBusyAfter`` is zero by default). It also answers
    /// `busy` when it cannot update now, such as an unreachable machine or another update running.
    func update(to build: DaemonBuildCommit, whileBusy: Bool) async -> DaemonUpdateOutcome
    /// Whether the target updates as soon as the policy reaches it: the policy queues it also when
    /// its build is unknown, ahead of every other waiting target and without waiting out another
    /// target's backoff; still one target at a time, once per build. The idle check stays the
    /// target's own (``update(to:whileBusy:)``): only a target that loses nothing by updating at
    /// once is urgent, such as a Cloud machine whose daemon the app refused. False by default; an
    /// acpmux ssh peer never is.
    var urgent: Bool { get async }
}

extension DaemonUpdateTarget {
    public nonisolated var urgent: Bool {
        get async { false }
    }
}

/// What one ``DaemonUpdateTarget/update(to:whileBusy:)`` did.
public nonisolated enum DaemonUpdateOutcome: Sendable, Equatable {
    /// The target now runs the build (`build`: what it reports, when it says).
    case updated(build: String?)
    /// It already did; nothing changed.
    case current
    /// It is not idle, or, asked to update while busy, it cannot now (unreachable, another update
    /// running); nothing changed. The policy asks again later.
    case busy
    /// No binary for its platform (`target`, a Rust triple) could be found; nothing changed. The
    /// next launch asks again.
    case needsBinary(target: String)
    /// The new daemon did not come up; the target put its previous build back.
    case rolledBack(reason: String)
    /// Another path updates it (a cmux Cloud VM reached as an ssh peer goes through
    /// `cmux link machine update --to-bundled`); nothing changed and nothing shows.
    case handledElsewhere
    /// The machine cannot take any new build in place (a Cloud machine whose cmux predates in-place
    /// updates); nothing changed, and it keeps working on what it runs. Not a failure: no toast,
    /// one grouped line in Settings > Updates, and not tried again while it reports the same build,
    /// whatever the app's build (``DaemonUpdateLedger/cannotUpdate``). `reason` says what still works.
    case unsupported(reason: String)
    case failed(reason: String)
}

/// The commit of a build string (`<hash>[+dirty.x] <date>`, acpmux `build.rs`, or a 40-hex
/// commit). Builds are the same by commit only: two builds of one commit differ in their date.
/// The date only orders two builds of different commits (``isNewer(than:)``).
public nonisolated struct DaemonBuildCommit: Sendable, Equatable {
    /// The hash, lowercased (9 hex for an acpmux build, 40 for a commit).
    public let hash: String
    /// Built from a tree with local changes (`+dirty.x`): never pushed to other machines, and a
    /// machine that runs one is someone's own build, never replaced.
    public let dirty: Bool
    /// The build's commit date (`YYYY-MM-DD`), nil when the string has none (a bare commit).
    public let date: String?

    /// Nil for no build, one without a hex hash (`nogit`), and any string not of that form: a
    /// `+` suffix other than `dirty.` and 8 hex, a second word that is not a `YYYY-MM-DD` day, or
    /// a third word. The policy leaves a machine whose build it cannot read alone, and pushes
    /// nothing from such a bundled build.
    public init?(_ build: String?) {
        let tokens = build?.split(whereSeparator: \.isWhitespace) ?? []
        guard let token = tokens.first, tokens.count <= 2 else { return nil }
        let parts = token.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hash = parts.first, (7...40).contains(hash.count), Self.isHex(hash) else { return nil }
        if parts.count > 1 {
            let suffix = parts[1]
            guard suffix.hasPrefix("dirty."), suffix.count == 14, Self.isHex(suffix.dropFirst(6)) else { return nil }
        }
        var date: String?
        if tokens.count == 2 {
            guard let day = Self.day(String(tokens[1])) else { return nil }
            date = day
        }
        self.hash = hash.lowercased()
        dirty = parts.count > 1
        self.date = date
    }

    private static func isHex(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `text` when it is a `YYYY-MM-DD` day, else nil.
    private static func day(_ text: String) -> String? {
        let digits = text.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? character == "-" : character.isASCII && character.isNumber
        }
        return text.count == 10 && digits ? text : nil
    }

    /// Built on a later day than `other`: a machine that runs such a build got it from somewhere
    /// newer than this app (a Linux host's own `acpmux-update.timer` follows feat-cmux-next), and
    /// the app never moves it back. False when either date is unknown or both are one day.
    public func isNewer(than other: DaemonBuildCommit) -> Bool {
        guard let date, let otherDate = other.date else { return false }
        return date > otherDate
    }

    /// One commit, also when the two hashes were cut at different lengths. False for `other`
    /// shorter than 7 or not hex.
    public func sameCommit(_ other: String) -> Bool {
        let other = other.lowercased()
        guard other.count >= 7, Self.isHex(Substring(other)) else { return false }
        return hash.hasPrefix(other) || other.hasPrefix(hash)
    }
}

/// One step of a target's update, for the board and the log.
public nonisolated struct DaemonUpdateEvent: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case updating
        /// The target could not update now (unreachable, another update running, or, with a
        /// non-zero ``DaemonUpdatePolicy/Dependencies/updateBusyAfter``, not idle yet): the policy
        /// asks again with backoff.
        case retrying
        case updated(build: String)
        /// `rolledBack`: the target put its previous build back.
        case failed(reason: String, rolledBack: Bool)
        /// The target cannot take a build in place (``DaemonUpdateOutcome/unsupported(reason:)``):
        /// never a toast; `reason` names it and says what still works.
        case cannotUpdate(reason: String)
        /// No update state: the board forgets the target.
        case cleared
    }

    public var id: String
    public var displayName: String
    public var sshHost: String?
    public var state: State
    /// Show a notice: a failure recorded for this build, which happens once per target and build.
    public var notify: Bool
    /// The bundled build's commit (``DaemonBuildCommit/hash``) a final outcome is about, so a
    /// surface can tell whether the target reached it since; nil for the other states.
    public var build: String?

    public init(id: String, displayName: String, sshHost: String? = nil, state: State, notify: Bool = false, build: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.sshHost = sshHost
        self.state = state
        self.notify = notify
        self.build = build
    }

    public init(_ target: any DaemonUpdateTarget, _ state: State, notify: Bool = false, build: String? = nil) {
        self.init(id: target.id, displayName: target.displayName, sshHost: target.sshHost, state: state, notify: notify, build: build)
    }
}
