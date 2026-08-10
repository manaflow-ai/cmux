import CmuxMobileSupport
import Foundation

struct AgentFeedL10n {
    private init() {}

    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        L10n.string(key, defaultValue: defaultValue, bundle: .module)
    }
}
