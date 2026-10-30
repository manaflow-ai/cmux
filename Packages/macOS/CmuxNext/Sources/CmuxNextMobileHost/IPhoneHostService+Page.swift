public import CmuxNextMobile
public import CmuxNextSettings
import Foundation

/// The Mobile page's iPhone card (`iphone` in `cmux.settings.host.lists`), every text localized
/// here. The switch above it is the schema row `mobile.allowIPhoneConnections`.
extension IPhoneHostService {
    /// The card as the page reads it, every text localized.
    public var pageJSON: JSONValue {
        [
            "title": .string(IPhoneHostStrings.connectionTitle),
            "allowed": .bool(allowed),
            "status_title": .string(IPhoneHostStrings.statusTitle),
            "status": .string(statusText),
            "phase": .string(phaseName),
            "account_title": .string(IPhoneHostStrings.accountTitle),
            "account": account.map { .string(IPhoneHostStrings.registered(as: $0.email ?? $0.userID)) } ?? .null,
            "space_title": .string(IPhoneHostStrings.spaceTitle),
            "space": account.map { .string($0.teamName ?? IPhoneHostStrings.personalSpace) } ?? .null,
            "how_title": .string(IPhoneHostStrings.howTitle),
            "how": .string(IPhoneHostStrings.how),
            "phones_title": .string(IPhoneHostStrings.phonesTitle),
            "phones_empty": .string(IPhoneHostStrings.phonesEmpty),
            "phones": .array(phoneRows),
            "phones_error": phonesError.map(JSONValue.string) ?? .null,
            "remove_title": .string(IPhoneHostStrings.remove),
            "remove_help": .string(IPhoneHostStrings.removeHelp),
            // Shown with phase "removed": the person's way to let iPhones connect again.
            "allow_again_title": .string(IPhoneHostStrings.allowAgain),
            // Phones asking to pair (cmux-next-ios verify/phone-approvals.md): Allow and Don't Allow
            // here are the person's own gesture, as in the prompt.
            "pending_title": .string(IPhoneHostStrings.pendingTitle),
            "pending": .array(pendingRows),
            "pair_allow_title": .string(IPhoneHostStrings.pairAllow),
            "pair_deny_title": .string(IPhoneHostStrings.pairDeny),
            "blocked": allowed && prompts.blocked > 0 ? .string(IPhoneHostStrings.blocked(prompts.blocked)) : .null,
            "blocked_help": .string(IPhoneHostStrings.blockedHelp),
        ]
    }

    /// `mobile.allowIPhoneConnections` as the service follows it (the Mobile Pairing page's switch).
    public var allowsConnections: Bool { allowed }

    /// hostd's phase (the Mobile Pairing page's step).
    public var phase: MobileHostState.Phase { state.phase }

    /// What a removed Mac says (the Mobile Pairing page's detail line).
    public static var removedText: String { IPhoneHostStrings.removed }

    /// The waiting pairing requests, oldest first: who asks, as which account, since when.
    private var pendingRows: [JSONValue] {
        guard allowed else { return [] }
        return prompts.pending.map { request in
            var facts = [IPhoneHostStrings.signedInAs(account?.email ?? account?.userID ?? "")]
            if let registered = request.registeredAt { facts.append(IPhoneHostStrings.deviceRegistered(registered)) }
            facts.append(IPhoneHostStrings.pairKey(MobileHostPairedDevices.fingerprint(request.approvalKey)))
            return ["id": .string(request.phoneDeviceID), "title": .string(IPhoneHostStrings.noticeTitle(Self.displayName(request))),
                    "subtitle": .string(facts.joined(separator: " · "))]
        }
    }

    /// The account's phones (known to the service) with their live link if one is up, then any
    /// live link the list does not have yet. Only a known phone can be removed.
    /// The phones Settings > Devices lists (plans/cmux-next/add-device-DESIGN.md 2.4): each one the
    /// account knows, and whether it has a live link now. Remove is ``removePhone(id:)``.
    /// A paired phone's row is its link id, the id its acpmux record is named for (its Full-access
    /// switch); Remove takes any of its ids.
    public var devicePhones: [(id: String, name: String, connected: Bool)] {
        guard allowed else { return [] }
        return knownPhones.map { phone in
            (paired?.pairing(of: phone)?.id ?? phone.id, phone.name, state.phones.contains { phone.owns($0.phoneDeviceID) })
        }
    }

    private var phoneRows: [JSONValue] {
        guard allowed else { return [] }
        let links = state.phones
        var rows: [JSONValue] = knownPhones.map { phone in
            let link = links.first { phone.owns($0.phoneDeviceID) }
            // Paired here (cmux-next-ios verify/phone-approvals.md): its links and Face ID approvals
            // count; Remove also forgets the pairing.
            let pairing = paired?.pairing(of: phone)
            return ["id": .string(phone.id), "title": .string(phone.name),
                    "subtitle": .string(link.map(Self.subtitle) ?? IPhoneHostStrings.notConnected),
                    "connected": .bool(link != nil), "removable": .bool(true),
                    "paired": .bool(pairing != nil), "fingerprint": pairing.map { .string($0.fingerprint) } ?? .null,
                    "transport": link.map { .string($0.transport) } ?? .null, "path": link.map { .string($0.path) } ?? .null]
        }
        for link in links where !knownPhones.contains(where: { $0.owns(link.phoneDeviceID) }) {
            rows.append(["id": .string(link.sessionID), "title": .string(IPhoneHostStrings.phone(String(link.phoneDeviceID.prefix(4)))),
                         "subtitle": .string(Self.subtitle(link)), "connected": .bool(true), "removable": .bool(false),
                         "transport": .string(link.transport), "path": .string(link.path)])
        }
        return rows
    }

    private var phaseName: String {
        guard allowed else { return "off" }
        switch state.phase {
        case .off: return "off"
        case .unavailable: return "unavailable"
        case .connecting: return "connecting"
        case .online: return "online"
        case .waiting: return "waiting"
        case .removed: return "removed"
        }
    }

    /// One line: the phase, then what matters in it (the phone count, or why it waits).
    private var statusText: String {
        guard allowed else { return account == nil ? IPhoneHostStrings.signedOut : IPhoneHostStrings.off }
        switch state.phase {
        case .off: return account == nil ? IPhoneHostStrings.signedOut : IPhoneHostStrings.off
        case .unavailable(let reason): return reason
        case .connecting: return IPhoneHostStrings.connecting
        case .online:
            return [IPhoneHostStrings.online, IPhoneHostStrings.phonesConnected(state.phones.count)].joined(separator: " · ")
        case .removed: return IPhoneHostStrings.removed
        case .waiting(let reason):
            return reason.isEmpty ? IPhoneHostStrings.reconnecting : "\(IPhoneHostStrings.reconnecting) (\(reason))"
        }
    }

    static func subtitle(_ phone: MobileHostPhoneLink) -> String {
        var parts = [IPhoneHostStrings.transport(phone.transport), IPhoneHostStrings.path(phone.path)]
        if let media = phone.mediaPath { parts.append(IPhoneHostStrings.videoWebRTC(media)) }
        if let since = phone.since {
            parts.append(IPhoneHostStrings.since(since.formatted(date: .omitted, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }
}
