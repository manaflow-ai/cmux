#if DEBUG
import Foundation
import Observation
import SwiftUI

/// App-owned tuning state shared by the lab and live sidebar.
@MainActor
@Observable
final class CloudSidebarDebugSettings {
    static let defaultsKey = "cloudTree.debugMetrics"
    @ObservationIgnored private let defaults: UserDefaults
    var metrics: CloudSidebarDebugMetrics {
        didSet {
            guard metrics != oldValue, let data = try? JSONEncoder().encode(metrics) else { return }
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        metrics = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(CloudSidebarDebugMetrics.self, from: $0) } ?? .default
    }

    deinit {}
}

extension EnvironmentValues {
    @Entry var cloudSidebarDebugSettings: CloudSidebarDebugSettings? = nil
}
#endif
