import CmuxNextMobile
import CmuxNextSettings
import Foundation

/// The Mobile page's iPhone card (`iphone` in `cmux.settings.host.lists`), every text localized
/// here. The switch above it is the schema row `mobile.allowIPhoneConnections`.
extension IPhoneHostService {
    var pageJSON: JSONValue {
        let phones = allowed ? state.phones : []
        return [
            "title": .string(IPhoneHostStrings.connectionTitle),
            "allowed": .bool(allowed),
            "status_title": .string(IPhoneHostStrings.statusTitle),
            "status": .string(statusText),
            "phase": .string(phaseName),
            "space_title": .string(IPhoneHostStrings.spaceTitle),
            "space": account.map { .string($0.teamName ?? IPhoneHostStrings.personalSpace) } ?? .null,
            "how_title": .string(IPhoneHostStrings.howTitle),
            "how": .string(IPhoneHostStrings.how),
            "phones_title": .string(IPhoneHostStrings.phonesTitle),
            "phones_empty": .string(IPhoneHostStrings.phonesEmpty),
            "phones": .array(phones.map { phone in
                ["id": .string(phone.sessionID), "title": .string(IPhoneHostStrings.phone(String(phone.phoneDeviceID.prefix(4)))),
                 "subtitle": .string(Self.subtitle(phone)), "transport": .string(phone.transport), "path": .string(phone.path)]
            }),
        ]
    }

    private var phaseName: String {
        guard allowed else { return "off" }
        switch state.phase {
        case .off: return "off"
        case .unavailable: return "unavailable"
        case .connecting: return "connecting"
        case .online: return "online"
        case .waiting: return "waiting"
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
        case .waiting(let reason):
            return reason.isEmpty ? IPhoneHostStrings.reconnecting : "\(IPhoneHostStrings.reconnecting) (\(reason))"
        }
    }

    static func subtitle(_ phone: CnxPhoneLink) -> String {
        var parts = [IPhoneHostStrings.transport(phone.transport), IPhoneHostStrings.path(phone.path)]
        if let since = phone.since {
            parts.append(IPhoneHostStrings.since(since.formatted(date: .omitted, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }
}
