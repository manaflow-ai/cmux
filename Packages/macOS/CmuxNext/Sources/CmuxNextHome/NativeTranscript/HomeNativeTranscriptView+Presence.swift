import AppKit
import CmuxHomeCore
import CmuxNextDesign
import MessagesLabHome

/// Chat multiplayer in the native Home chat (Leo, 2026-10-26: "also chief chats we need
/// multiplayer"; hq plans/cmux-next/chat-multiplayer/DESIGN.md): who else has this conversation
/// open, from the owner's presence (`HomeStore.viewing`), as faces beside the header's name pill,
/// the same letters and colors as the agent chat's header (`PresenceStack`, Faces.tsx).
extension HomeNativeTranscriptView {
    /// Who else has the conversation open, by name (from `participants`, the conversation's own,
    /// else their id), without `me`, in name order.
    static func others(viewing: Set<ParticipantID>, participants: [Participant], me: ParticipantID) -> [String] {
        let others = viewing.subtracting([me])
        guard !others.isEmpty else { return [] }
        var names: [ParticipantID: String] = [:]
        for person in participants where others.contains(person.id) && names[person.id] == nil {
            let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[person.id] = name }
        }
        return others.map { names[$0] ?? $0.rawValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// One face for `name`: its first letter on the name's own color (`MachineColor`, the hash the
    /// agent chat's faces use, so one person keeps one color in both).
    @MainActor static func face(_ name: String) -> PaneHeaderFace {
        PaneHeaderFace(initial: name.first.map { String($0).uppercased() } ?? "?", color: MachineColor(name: name).color)
    }

    /// Keeps the header's faces on the store's presence for this conversation, until `stop()`.
    func followPresence() {
        guard !stopped else { return }
        let store = binding.store, id = binding.conversation, me = self.me
        // Reads the conversation's own summary (one lookup) only while someone else is here, so
        // with nobody here a message or typing change does no work here at all; the rows only for
        // a person the conversation does not name.
        let names = withObservationTracking { () -> [String] in
            let viewing = store.viewing[id] ?? []
            guard !viewing.subtracting([me]).isEmpty else { return [] }
            var people = store.summary(id)?.participants ?? []
            // Someone the conversation does not list (a teammate looking in on a Chief chat): their
            // name from another conversation; only then are the rows read.
            let unnamed = viewing.subtracting([me]).subtracting(people.map(\.id))
            if !unnamed.isEmpty {
                people += store.rows.lazy.flatMap(\.summary.participants).filter { unnamed.contains($0.id) }
            }
            return HomeNativeTranscriptView.others(viewing: viewing, participants: people, me: me)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followPresence() }
        }
        let label = names.isEmpty ? "" : HomeStrings.alsoHere(names.formatted(.list(type: .and)))
        transcript.setHeaderFaces(names.map(HomeNativeTranscriptView.face), label: label)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The header's faces as drawn now: each initial, whether they show, and what VoiceOver reads
    /// (`debug.home.drive` `faces`, tests).
    public var debugHeaderFaces: (initials: [String], shown: Bool, label: String) {
        let drawn = transcript.debugHeaderFaces
        return (drawn.faces.map(\.initial), drawn.shown, drawn.label)
    }
    #endif
}
