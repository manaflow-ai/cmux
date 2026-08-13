import CmuxMobileSupport
import Foundation
import SwiftUI

struct AgentFeedLocalizer {
    let bundle: Bundle

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        L10n.string(key, defaultValue: defaultValue, bundle: bundle)
    }
}

private struct AgentFeedLocalizerKey: EnvironmentKey {
    static let defaultValue = AgentFeedLocalizer()
}

extension EnvironmentValues {
    var agentFeedLocalizer: AgentFeedLocalizer {
        get { self[AgentFeedLocalizerKey.self] }
        set { self[AgentFeedLocalizerKey.self] = newValue }
    }
}
