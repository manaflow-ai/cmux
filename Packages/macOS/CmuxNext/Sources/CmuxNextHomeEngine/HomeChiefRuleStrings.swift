import CmuxNextHomeModel
import Foundation

/// The localized words the `chief_settings.*` rules put in what they return (cmux-home-rules
/// `chief_settings::Strings`), filled from ``HomeEngineStrings``, ``HomeStrings`` and
/// ``ChiefBackend``. Every op that titles or words something gets all of them, so the Rust side's
/// English defaults never stand in for the app's own strings.
nonisolated struct HomeChiefRuleStrings: Encodable {
    var recentSection = HomeEngineStrings.recentSection
    var planAndExecuteSection = HomeEngineStrings.planAndExecuteSection
    var otherModelsSection = HomeEngineStrings.otherModelsSection
    var olderModelsSection = HomeEngineStrings.olderModelsSection
    var opusPlanTitle = HomeEngineStrings.opusPlanTitle
    var contextVariantFormat = HomeEngineStrings.contextVariantFormat
    var defaultValue = HomeEngineStrings.defaultValue
    var defaultNamedFormat = HomeEngineStrings.defaultNamedFormat
    var efforts = Dictionary(uniqueKeysWithValues: ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map {
        ($0, HomeEngineStrings.effortTitle($0))
    })
    var backends = Dictionary(uniqueKeysWithValues: ChiefBackend.official.map { ($0.id, $0.title) })
    var hints = Dictionary(uniqueKeysWithValues: ChiefBackend.official.compactMap { backend in backend.hint.map { (backend.id, $0) } })
    var chiefName = HomeStrings.chiefName
    var homeTitle = HomeStrings.title
    var errors: [String: String] = [
        "unreachable": HomeEngineStrings.errorUnreachable,
        "localUnreachable": HomeEngineStrings.errorLocalUnreachable,
        "localStarting": HomeEngineStrings.errorLocalStarting,
        "forbidden": HomeEngineStrings.errorForbidden,
        "notConfigured": HomeEngineStrings.errorNotConfigured,
        "unsupported": HomeEngineStrings.errorUnsupported,
        "agentsDisabled": HomeStrings.chiefAgentsDisabled,
        "cloudUnreachable": HomeEngineStrings.errorCloudUnreachable,
        "signedOut": HomeEngineStrings.errorSignedOut,
        "cloudUnavailable": HomeEngineStrings.errorCloudUnavailable,
        "cloudStopUnsupported": HomeEngineStrings.errorCloudStopUnsupported,
        "refused": HomeEngineStrings.errorRefusedFormat,
    ]
}
