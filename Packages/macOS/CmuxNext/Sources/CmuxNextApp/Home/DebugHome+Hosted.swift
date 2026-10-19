import CmuxNextSettings
import Foundation

/// `debug.home` `hosted_chief`: the Chief tab's two cloud Chiefs, the user's
/// choice, the copy ledger and the brain state, for the Hosted Chief proof
/// (scripts/cmux-next/hosted-chief-proof.py). `debug.home.api`
/// `{call: "chief_switch", choice: "hosted"|"placed"}` takes the path of the
/// Chief tab's switch (``HomeChiefSwitch``).
extension DebugHome {
    static func hosted(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        func chief(_ chief: CloudChief?) -> CmuxNextSettings.JSONValue {
            guard let chief else { return .null }
            return .object(["id": .string(chief.id), "name": .string(chief.displayName), "default": .bool(chief.isDefault),
                            "main": chief.mainConversation.map { .string($0) } ?? .null, "placed": .bool(chief.brainPlace != nil)])
        }
        let ledger = HostedChiefLedger(session: home.chief.home.session)
        let steps: CmuxNextSettings.JSONValue = home.cloudChiefs.hosted.map { hosted in
            .object(Dictionary(uniqueKeysWithValues: [HostedChiefLedger.Step.history, .memory, .brain].map { ($0.rawValue, CmuxNextSettings.JSONValue.bool(ledger.done($0, chief: hosted.id))) }))
        } ?? .null
        return .object([
            "hosted": chief(home.cloudChiefs.hosted), "placed": chief(home.cloudChiefs.placed),
            "choice": .string(home.chiefChoice.rawValue), "can_switch": .bool(home.tabChiefs.canSwitch),
            "shown": home.cloudChief?.mainConversation.map { .string($0) } ?? .null,
            "pending": .bool(home.hostedPending), "running": .bool(home.hostedMigration != nil),
            "brain_on": home.hostedBrainOn.map { .bool($0) } ?? .null,
            "notice": home.hostedNotice.map { .string($0) } ?? .null,
            "ledger": steps, "account": ledger.account.map { .string($0) } ?? .null,
        ])
    }
}
