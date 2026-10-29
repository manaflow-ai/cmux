package import CmuxHomeCore

/// Where `home.stopChief` and `home.toggleChiefSettings` act when they run from anywhere (the
/// palette, a menu, `cmux action run`), not only from a Home in front. Pure: the handler reads the
/// front window's Home and the inbox's Chief rows, this decides.
package struct HomeChiefActionPlan {
    /// A Chief conversation in the inbox.
    package struct Chief: Equatable {
        package var conversation: ConversationID
        /// Its turn runs (the row types).
        package var isWorking: Bool
        /// This Mac's default Chief (`HomeChiefName.select`), preferred over the others.
        package var isDefault: Bool

        package init(conversation: ConversationID, isWorking: Bool, isDefault: Bool) {
            self.conversation = conversation
            self.isWorking = isWorking
            self.isDefault = isDefault
        }
    }

    /// What the front window's Home shows.
    package enum Front: Equatable {
        /// No Home in front, or one that shows no Chief conversation.
        case none
        /// A Chief conversation, and whether its turn runs.
        case chief(isWorking: Bool)
    }

    /// What Stop does.
    package enum Stop: Equatable {
        /// The Home in front stops its own Chief.
        case front
        /// The Chief of this conversation stops, with no Home in front.
        case chief(ConversationID)
        /// Nothing runs: refused quietly (a key press shows nothing; a caller gets the reason).
        case nothingRuns
    }

    /// What Toggle Chief Settings does.
    package enum Settings: Equatable {
        /// The Home in front toggles its own Chief's settings.
        case front
        /// Home comes forward at this Chief's conversation and opens its settings.
        case open(ConversationID)
        /// No Chief exists: refused with a reason.
        case noChief
    }

    package let front: Front
    package let chiefs: [Chief]

    /// The Chief a Home in front shows wins, even when idle (Esc in its box never stops another
    /// Chief); else the working Chief, this Mac's default first.
    package var stop: Stop {
        switch front {
        case .chief(let isWorking): return isWorking ? .front : .nothingRuns
        case .none:
            let working = chiefs.filter(\.isWorking)
            guard let chief = working.first(where: \.isDefault) ?? working.first else { return .nothingRuns }
            return .chief(chief.conversation)
        }
    }

    /// The Home in front toggles; else this Mac's default Chief (or the first one) opens.
    package var settings: Settings {
        if case .chief = front { return .front }
        guard let chief = chiefs.first(where: \.isDefault) ?? chiefs.first else { return .noChief }
        return .open(chief.conversation)
    }

    package init(front: Front, chiefs: [Chief]) {
        self.front = front
        self.chiefs = chiefs
    }
}
