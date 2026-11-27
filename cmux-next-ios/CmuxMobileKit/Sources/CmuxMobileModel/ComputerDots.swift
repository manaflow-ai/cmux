import Foundation

/// One computer's presence as a dot: green when the phone can reach it, red when not.
/// A computer is any Mac-kind device the team lists: a Mac, or a Cloud VM, whose daemon
/// registers as a Mac-kind device (PROTOCOL.md "hub": "the VM's daemon registers as one").
///
/// Leo, 2026-11-24: "x of x macs online is... hm. idk if we need to show that on the top
/// per se. it feels like we csn go more implied like... red dot green dot when you switch
/// between your computers' stuff. cuz it wont just be macs. like afaik this was only
/// [one Mac]'s so i dont need to see the others". So no count of the team's computers
/// shows anywhere: by default one dot, for the computer the current workspace lives on,
/// and one dot per computer where the user switches between them (the Filter menu).
public struct ComputerDot: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Green: reachable (or on its way). Red: offline, not responding, refused.
    public let isUp: Bool

    public init(id: String, name: String, isUp: Bool) {
        self.id = id
        self.name = name
        self.isUp = isUp
    }

    /// What VoiceOver reads for the dot ("Office Mac, online").
    public var spoken: String { "\(name), \(isUp ? "online" : "offline")" }
}

public enum ComputerDots {
    /// Green or red for one reachability. A dial under way, or an online computer the link is
    /// not on yet, is green: the phone keeps connecting optimistically and never shows limbo
    /// (Leo, 2026-11-24, item 2). With no network on the phone nothing new is known, so the
    /// last-known listed presence stays (`listedOnline`).
    public static func isUp(_ reach: MacReachability, listedOnline: Bool) -> Bool {
        switch reach {
        case .connected, .connecting, .notConnected: true
        case .phoneOffline: listedOnline
        case .slow, .offline, .noAnswer, .serviceDown, .authRequired, .notAllowed: false
        }
    }

    public static func dot(_ mac: MacDevice, name: String? = nil, reach: MacReachability) -> ComputerDot {
        ComputerDot(id: mac.id, name: name ?? mac.name, isUp: isUp(reach, listedOnline: mac.listedOnline))
    }

    /// The computer shown by default: the one the list is filtered to, else the one the
    /// current (last-opened) workspace lives on, else the one the phone's link is on, else the
    /// first listed online, else the first listed. Nil with no computers.
    public static func current(macs: [MacDevice], scopedMacID: String? = nil, workspaceMacID: String? = nil,
                               linkedMacID: String? = nil) -> MacDevice? {
        for id in [scopedMacID, workspaceMacID, linkedMacID].compactMap(\.self) {
            if let mac = macs.first(where: { $0.id == id }) { return mac }
        }
        return macs.first(where: \.isOnline) ?? macs.first
    }

    /// The Workspaces header: the current computer's dot, only when there is a choice of
    /// computers or one is chosen (one computer alone says nothing, as before), and the line
    /// beside it. Never a count of the computers online.
    public struct Header: Equatable, Sendable {
        public var dot: ComputerDot?
        public var text: String

        public init(dot: ComputerDot?, text: String) {
            self.dot = dot
            self.text = text
        }
    }

    /// - `scopedLine`: the filtered computer's presence line ("Online", "Offline · Last seen 4m ago").
    /// - `needsYou`: how many workspaces wait on the user.
    public static func header(macs: [MacDevice], scopedMacID: String?, workspaceMacID: String?, linkedMacID: String?,
                              needsYou: Int, scopedLine: String? = nil, name: (MacDevice) -> String = \.name,
                              reach: (MacDevice) -> MacReachability) -> Header {
        let waiting = needsYou <= 0 ? nil : needsYou == 1 ? "1 needs you" : "\(needsYou) need you"
        let scoped = scopedMacID.flatMap { id in macs.first { $0.id == id } }
        guard scoped != nil || macs.count > 1,
              let mac = current(macs: macs, scopedMacID: scopedMacID, workspaceMacID: workspaceMacID, linkedMacID: linkedMacID)
        else { return Header(dot: nil, text: waiting ?? "") }
        let dot = dot(mac, name: name(mac), reach: reach(mac))
        let detail = scoped != nil ? scopedLine : waiting
        return Header(dot: dot, text: [dot.name, detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// A team row's dot (the team drawer, the team picker): the team's current computer, not
    /// one dot per computer. `workspaceMacID`: the current workspace's computer when the team
    /// is the active one. Nil when the team has no computers.
    /// `reach`: the computer's reachability (the active team's, from its link); by default
    /// what the cmux service lists (``listed(_:)``).
    public static func team(_ team: Team, workspaceMacID: String? = nil, linkedMacID: String? = nil,
                            reach: (MacDevice) -> MacReachability = ComputerDots.listed) -> ComputerDot? {
        let macs = team.listedMacs
        guard let mac = current(macs: macs, workspaceMacID: workspaceMacID, linkedMacID: linkedMacID ?? team.pickedMacID) else {
            return nil
        }
        return dot(mac, reach: reach(mac))
    }

    /// The reachability the cmux service's listing alone says (no link): online or offline.
    public static func listed(_ mac: MacDevice) -> MacReachability {
        mac.isOnline ? .connected : .offline(lastSeenAt: mac.lastSeenAt)
    }
}
