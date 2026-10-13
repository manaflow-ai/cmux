import CmuxNextMobile
import CmuxNextSettings
import Foundation

/// The iPhone card of the Settings page (`iphone` in `cmux.settings.host.lists`), every text localized here.
extension IPhoneHostService {
    var pageJSON: JSONValue {
        let phones = allowed ? state.phones : []
        return [
            "title": .string(IPhoneHostStrings.title),
            "allowed": .bool(allowed),
            "enabled": .bool(dependencies?.executable != nil && (account != nil || allowed)),
            "allow_title": .string(IPhoneHostStrings.allowTitle),
            "allow_help": .string(IPhoneHostStrings.allowHelp),
            "status_title": .string(IPhoneHostStrings.statusTitle),
            "status": .string(statusText),
            "phase": .string(phaseName),
            "how_title": .string(IPhoneHostStrings.howTitle),
            "how": .string(IPhoneHostStrings.how),
            "phones_title": .string(IPhoneHostStrings.phonesTitle),
            "phones_empty": .string(IPhoneHostStrings.phonesEmpty),
            "phones": .array(phones.map { phone in
                ["id": .string(phone.sessionID), "title": .string(IPhoneHostStrings.phone(String(phone.phoneDeviceID.prefix(4)))),
                 "subtitle": .string(Self.subtitle(phone))]
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

    /// One line: the phase, then what matters in it (phones, the space, or why it waits).
    private var statusText: String {
        guard allowed else { return account == nil ? IPhoneHostStrings.signedOut : IPhoneHostStrings.off }
        switch state.phase {
        case .off: return account == nil ? IPhoneHostStrings.signedOut : IPhoneHostStrings.off
        case .unavailable(let reason): return reason
        case .connecting: return IPhoneHostStrings.connecting
        case .online:
            let space = account?.teamName ?? IPhoneHostStrings.personalSpace
            return [IPhoneHostStrings.online, IPhoneHostStrings.phonesConnected(state.phones.count),
                    IPhoneHostStrings.space(space)].joined(separator: " · ")
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
