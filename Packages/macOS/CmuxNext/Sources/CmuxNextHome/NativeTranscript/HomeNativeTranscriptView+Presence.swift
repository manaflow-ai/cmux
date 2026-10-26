import AppKit
import CmuxHomeCore
import CmuxNextDesign
import MessagesLabHome

/// Chat multiplayer in the native Home chat (Leo, 2026-10-26: "also chief chats we need
/// multiplayer"; hq plans/cmux-next/chat-multiplayer/DESIGN.md): who else has this conversation
/// open, from the owner's presence (`HomeStore.viewing`), as faces beside the header's name pill,
/// the same letters and colors as the agent chat's header (`PresenceStack`, Faces.tsx).
extension HomeNativeTranscriptView {
    /// Who else has `conversation` open, by name (the first in any row that names them, else
    /// their id), without `me`, in name order.
    static func others(viewing: Set<ParticipantID>, rows: [InboxRow], me: ParticipantID) -> [String] {
        var names: [ParticipantID: String] = [:]
        for row in rows {
            for person in row.summary.participants where names[person.id] == nil {
                let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { names[person.id] = name }
            }
        }
        return viewing.subtracting([me]).map { names[$0] ?? $0.rawValue }
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
        let names = withObservationTracking {
            HomeNativeTranscriptView.others(viewing: store.viewing[id] ?? [], rows: store.rows, me: me)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followPresence() }
        }
        let label = names.isEmpty ? "" : HomeStrings.alsoHere(names.formatted(.list(type: .and)))
        transcript.setHeaderFaces(names.map(HomeNativeTranscriptView.face), label: label)
    }

    /// The header's faces as drawn now: each initial, and whether they show (`debug.home.drive` `faces`).
    public var debugHeaderFaces: (initials: [String], shown: Bool) {
        let drawn = transcript.headerFaces
        return (drawn.faces.map(\.initial), drawn.shown)
    }
}
