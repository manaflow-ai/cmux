import CmuxHomeCore

/// Where `home.stopChief` and `home.toggleChiefSettings` act when they run from anywhere (the
/// palette, a menu, `cmux action run`), not only from a Home in front. Pure: the handler reads the
/// front window's Home and the inbox's Chief rows, this decides.
struct HomeChiefActionPlan {
    /// A Chief conversation in the inbox.
    struct Chief: Equatable {
        var conversation: ConversationID
        /// Its turn runs (the row types).
        var isWorking: Bool
        /// This Mac's default Chief (`HomeChiefName.select`), preferred over the others.
        var isDefault: Bool
    }

    /// What the front window's Home shows.
    enum Front: Equatable {
        /// No Home in front, or one that shows no Chief conversation.
        case none
        /// A Chief conversation, and whether its turn runs.
        case chief(isWorking: Bool)
    }

    /// What Stop does.
    enum Stop: Equatable {
        /// The Home in front stops its own Chief.
        case front
        /// The Chief of this conversation stops, with no Home in front.
        case chief(ConversationID)
        /// Nothing runs: refused quietly (a key press shows nothing; a caller gets the reason).
        case nothingRuns
    }

    /// What Toggle Chief Settings does.
    enum Settings: Equatable {
        /// The Home in front toggles its own Chief's settings.
        case front
        /// Home comes forward at this Chief's conversation and opens its settings.
        case open(ConversationID)
        /// No Chief exists: refused with a reason.
        case noChief
    }

    let front: Front
    let chiefs: [Chief]

    /// The Chief a Home in front shows wins, even when idle (Esc in its box never stops another
    /// Chief); else the working Chief, this Mac's default first.
    var stop: Stop {
        switch front {
        case .chief(let isWorking): return isWorking ? .front : .nothingRuns
        case .none:
            let working = chiefs.filter(\.isWorking)
            guard let chief = working.first(where: \.isDefault) ?? working.first else { return .nothingRuns }
            return .chief(chief.conversation)
        }
    }

    /// The Home in front toggles; else this Mac's default Chief (or the first one) opens.
    var settings: Settings {
        if case .chief = front { return .front }
        guard let chief = chiefs.first(where: \.isDefault) ?? chiefs.first else { return .noChief }
        return .open(chief.conversation)
    }
}
