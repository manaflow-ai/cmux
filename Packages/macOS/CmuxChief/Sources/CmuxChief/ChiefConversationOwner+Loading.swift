public import CmuxHomeCore
public import Foundation

/// The conversations read from a Chief home, before an owner holds them.
struct ChiefLoadedConversations: Sendable {
    var conversations: [ConversationID: ChiefConversationState] = [:]
    /// The file of each conversation the owner may append to. A conversation
    /// without one stays in memory only (its file could not be written safely).
    var files: [ConversationID: URL] = [:]
    /// What went wrong per file, for diagnostics (``ChiefConversationOwner/loadProblems``).
    var problems: [String] = []
}

// Loading: reading every conversation file off the main thread, setting damaged
// files aside, and settling what a previous run left open.
extension ChiefConversationOwner {
    /// The decided value of an approval card whose turn ended with an earlier
    /// run of the app: nobody can answer it any more. Home shows it as
    /// "Expired"; it is never one of the card's options.
    public static let approvalExpired = "expired"

    /// Opens (or creates) the Chief home and loads its conversations on a
    /// background task, so the caller's thread (the main thread at launch)
    /// never reads or rewrites conversation files.
    ///
    /// A file that cannot be read or decoded never stops the load: a damaged
    /// file is kept as `<name>.corrupt-<time>.jsonl` and its readable records
    /// are used, an unreadable one is skipped, and the default conversation
    /// is always available (``loadProblems`` lists what happened).
    ///
    /// - Parameters: The same as ``init(home:brain:userDisplayName:now:context:)``.
    /// - Returns: The owner, ready to serve.
    /// - Throws: A file system error when the home's directories cannot be created.
    public static func load(
                            home: ChiefHome,
                            brain: any ChiefBrain,
                            userDisplayName: String? = nil,
                            allowRules: ChiefAllowRules = ChiefAllowRules(),
                            now: @escaping @Sendable () -> Date = { Date() },
                            clock: any Clock<Duration> = ContinuousClock(),
                            context: @escaping ChiefTurnContextProvider) async throws -> ChiefConversationOwner {
        allowRules.load(home)
        let loaded = try await Task.detached(priority: .userInitiated) {
            let people = Self.participants(userDisplayName: userDisplayName)
            return (people, try Self.loadConversations(home: home, me: people.me, chief: people.chief, now: now))
        }.value
        return ChiefConversationOwner(home: home, brain: brain, allowRules: allowRules,
                                      me: loaded.0.me, chief: loaded.0.chief, now: now,
                                      clock: clock, context: context, loaded: loaded.1)
    }

    /// The user and the default Chief.
    static func participants(userDisplayName: String?) -> (me: Participant, chief: Participant) {
        let fullName = userDisplayName ?? NSFullUserName()
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = Participant(id: userID, kind: .human, displayName: name.isEmpty ? ChiefText.you : name)
        let defaultChief = Participant(id: chiefID, kind: .agent, displayName: "Chief", agentClass: .chief, ownerUser: userID)
        return (user, defaultChief)
    }

    /// Reads every conversation file of `home`.
    ///
    /// - Throws: A file system error when the home's directories cannot be created.
    static func loadConversations(home: ChiefHome, me: Participant, chief: Participant,
                                  now: @Sendable () -> Date) throws -> ChiefLoadedConversations {
        try home.createDirectories()
        var loaded = ChiefLoadedConversations()
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: home.conversationsDirectory, includingPropertiesForKeys: nil)
        } catch {
            files = []
            loaded.problems.append("conversations: \(error)")
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "jsonl" && !file.lastPathComponent.contains(ChiefConversationLog.corruptInfix) {
            loadFile(file, into: &loaded, now: now)
        }
        if loaded.conversations[defaultConversationID] == nil {
            let created = now()
            // Unpinned: Home lists it as a row; only the user pins conversations into the grid.
            let summary = ConversationSummary(id: defaultConversationID, owner: .local, participants: [me, chief],
                                              createdAt: created, updatedAt: created)
            let state = ChiefConversationState(summary: summary)
            loaded.conversations[summary.id] = state
            let url = file(for: summary.id, in: home)
            // Never write over a file this load could not read (it stays for a later run).
            if FileManager.default.fileExists(atPath: url.path) {
                loaded.problems.append("\(url.lastPathComponent): kept unread; the default conversation is not saved this run")
            } else if write(state, to: url, problems: &loaded.problems) {
                loaded.files[summary.id] = url
            }
        }
        return loaded
    }

    /// Loads one file. A damaged one is moved aside first; the file is rewritten
    /// as a compacted snapshot only when nothing would be lost by it.
    private static func loadFile(_ file: URL, into loaded: inout ChiefLoadedConversations, now: @Sendable () -> Date) {
        let name = file.lastPathComponent
        let result: ChiefConversationLoad
        do {
            result = try ChiefConversationLog.load(file)
        } catch {
            loaded.problems.append("\(name): unreadable, skipped: \(error)")
            return
        }
        var keptAside = false
        if result.damaged {
            do {
                let aside = try moveAside(file, now: now())
                keptAside = true
                loaded.problems.append("\(name): damaged lines; the original is kept as \(aside.lastPathComponent)")
            } catch {
                loaded.problems.append("\(name): damaged lines; could not keep the original: \(error)")
            }
        }
        guard var state = result.state else { return }
        guard loaded.conversations[state.id] == nil else {
            loaded.problems.append("\(name): a second file for \(state.id.rawValue), skipped")
            return
        }
        settleInterrupted(&state)
        loaded.conversations[state.id] = state
        // A damaged file that could not be kept aside is not rewritten: the rewrite would drop its bad lines for good.
        guard !result.damaged || keptAside else { return }
        if write(state, to: file, problems: &loaded.problems) { loaded.files[state.id] = file }
    }

    /// Writes `state` as the file's snapshot; false (and a problem) when that fails.
    private static func write(_ state: ChiefConversationState, to url: URL, problems: inout [String]) -> Bool {
        do {
            try ChiefConversationLog(url: url).rewrite(state)
            return true
        } catch {
            problems.append("\(url.lastPathComponent): could not be written: \(error)")
            return false
        }
    }

    /// Moves a damaged file to `<name>.corrupt-<time>.jsonl` next to it, never over another file.
    static func moveAside(_ file: URL, now: Date) throws -> URL {
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let target = directory.appendingPathComponent("\(base)\(ChiefConversationLog.corruptInfix)\(stamp)\(suffix).jsonl")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: file, to: target)
                return target
            }
            attempt += 1
        }
    }

    /// What an earlier run left open can never finish: its approval cards
    /// expire (``approvalExpired``) and its running work rows fail (Cloud result cards keep theirs).
    static func settleInterrupted(_ state: inout ChiefConversationState) {
        var settled: [Message] = []
        for message in state.messages {
            var changed = false
            let parts = message.parts.map { part -> MessagePart in
                switch part {
                case .approval(var ref) where ref.decided == nil:
                    ref.decided = approvalExpired
                    changed = true
                    return .approval(ref)
                // A Cloud result card (a machine `host`, not the provisioning row) reports a remote
                // agent's state, not a local call: it outlives the run ("Needs sign-in" stays).
                case .work(var work) where (work.status == .running || work.status == .waiting)
                    && (work.host == nil || ChiefCloudProvisioning.isProvisioning(work)):
                    work.status = .failed
                    changed = true
                    return .work(work)
                default:
                    return part
                }
            }
            if changed {
                var updated = message
                updated.parts = parts
                settled.append(updated)
            }
        }
        guard !settled.isEmpty else { return }
        for message in settled { state.upsert(message) }
        // A new revision, so a client's cached copy of the open cards is replaced.
        state.summary.rev += 1
    }
}
