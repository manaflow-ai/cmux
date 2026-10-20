public import CmuxHomeCore
import Foundation
public import Observation

/// The group info sheet's state: the conversation as the app last read it (``update(info:addable:)``),
/// the name being edited, the people being added and the status line. Each control runs one
/// ``HomeGroupInfoActions`` closure; a refusal stays in the status line.
@Observable @MainActor
public final class HomeGroupInfoModel {
    /// The conversation now.
    public private(set) var info: HomeGroupInfo
    /// The people the user may add (contacts not in it).
    public private(set) var addable: [HomeContact]
    /// The name field's text.
    var nameDraft: String
    /// The status line: why the last action did not finish (nil hides it).
    private(set) var status: String?
    /// The last refusal was `not_reachable`: Invite by Email… shows.
    private(set) var offersInvite = false
    private(set) var isRunning = false
    /// The Add People panel is open.
    var isAdding = false
    var search = ""
    private(set) var chosen: [ParticipantID] = []
    /// Closes the sheet (set by the sheet).
    @ObservationIgnored var close: @MainActor () -> Void = {}
    @ObservationIgnored private let actions: HomeGroupInfoActions
    // task-owner: the sheet's one running action; cancelled when a new one starts or the sheet closes
    @ObservationIgnored private var work: Task<Void, Never>?

    public init(info: HomeGroupInfo, addable: [HomeContact], actions: HomeGroupInfoActions) {
        self.info = info
        self.addable = addable
        self.actions = actions
        nameDraft = info.title
    }

    /// A newer read of the conversation; an unedited name follows it.
    public func update(info: HomeGroupInfo, addable: [HomeContact]) {
        if nameDraft == self.info.title { nameDraft = info.title }
        self.info = info
        self.addable = addable
        chosen.removeAll { id in !addable.contains { $0.id == id } }
    }

    /// The contacts the search shows.
    var shownAddable: [HomeContact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? addable : addable.filter { $0.name.localizedStandardContains(query) }
    }

    var canRename: Bool {
        !isRunning && nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != info.title
    }

    func toggle(_ id: ParticipantID) {
        if let at = chosen.firstIndex(of: id) { chosen.remove(at: at) } else { chosen.append(id) }
    }

    func isChosen(_ id: ParticipantID) -> Bool { chosen.contains(id) }

    func rename() {
        guard canRename else { return }
        let name = nameDraft
        run { await self.actions.rename(name) }
    }

    func addChosen() {
        let people = chosen
        let names = addable.filter { people.contains($0.id) }.map(\.name).joined(separator: ", ")
        run {
            let outcome = await self.actions.add(people, names)
            if outcome.succeeded {
                self.chosen = []
                self.isAdding = false
                self.search = ""
            }
            return outcome
        }
    }

    func remove(_ id: ParticipantID) {
        run { await self.actions.remove(id) }
    }

    func setMuted(_ on: Bool) {
        show(actions.setMuted(on))
    }

    func leave() {
        close()
        actions.leave()
    }

    func inviteByEmail() {
        close()
        actions.inviteByEmail()
    }

    func stop() { work?.cancel() }

    private func run(_ action: @escaping @MainActor () async -> HomeGroupOutcome) {
        guard !isRunning else { return }
        isRunning = true
        status = nil
        offersInvite = false
        work = Task { [weak self] in
            let outcome = await action()
            guard let self, !Task.isCancelled else { return }
            isRunning = false
            show(outcome)
        }
    }

    private func show(_ outcome: HomeGroupOutcome) {
        status = outcome.message
        if case .notReachable = outcome { offersInvite = true } else { offersInvite = false }
    }
}
