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
    /// Chief); else the working Chief, this Mac's default first (`dock.chief_action_plan`).
    package let stop: Stop
    /// The Home in front toggles; else this Mac's default Chief (or the first one) opens.
    package let settings: Settings

    package init(front: Front, chiefs: [Chief]) {
        self.front = front
        self.chiefs = chiefs
        let wireFront: Request.WireFront = switch front {
        case .none: Request.WireFront(type: "none", isWorking: nil)
        case .chief(let isWorking): Request.WireFront(type: "chief", isWorking: isWorking)
        }
        let request = Request(front: wireFront, chiefs: chiefs.map {
            Request.WireChief(conversation: $0.conversation.rawValue, isWorking: $0.isWorking, isDefault: $0.isDefault)
        })
        let plan: Plan = dockRule("dock.chief_action_plan", request,
                                  fallback: Plan(stop: DockTagged(type: "nothingRuns", conversation: nil), settings: DockTagged(type: "noChief", conversation: nil)))
        switch plan.stop.type {
        case "front": stop = .front
        case "chief": stop = plan.stop.conversation.map { .chief(ConversationID($0)) } ?? .nothingRuns
        default: stop = .nothingRuns
        }
        switch plan.settings.type {
        case "front": settings = .front
        case "open": settings = plan.settings.conversation.map { .open(ConversationID($0)) } ?? .noChief
        default: settings = .noChief
        }
    }

    private nonisolated struct Request: Encodable {
        nonisolated struct WireFront: Encodable { var type: String; var isWorking: Bool? }
        nonisolated struct WireChief: Encodable { var conversation: String; var isWorking: Bool; var isDefault: Bool }
        var front: WireFront
        var chiefs: [WireChief]
    }

    private nonisolated struct Plan: Decodable {
        var stop: DockTagged
        var settings: DockTagged
    }
}
