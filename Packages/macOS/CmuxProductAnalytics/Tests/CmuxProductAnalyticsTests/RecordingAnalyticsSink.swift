import CMUXMobileCore
import Foundation
import os

/// Records every sink call in order.
final class RecordingAnalyticsSink: AnalyticsEmitting {
    enum Call: Equatable {
        case capture(String, [String: AnalyticsValue])
        case identify(String?)
        case superProperties([String: AnalyticsValue])
    }

    // Sink calls arrive from the pipeline actor while tests read on their own task.
    private let state = OSAllocatedUnfairLock<[Call]>(initialState: [])

    var calls: [Call] { state.withLock { $0 } }

    var events: [(name: String, properties: [String: AnalyticsValue])] {
        calls.compactMap { call in
            if case let .capture(name, properties) = call { return (name: name, properties: properties) }
            return nil
        }
    }

    var eventNames: [String] { events.map(\.name) }

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        state.withLock { $0.append(.capture(event, properties)) }
    }

    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {
        state.withLock { $0.append(.identify(userId)) }
    }

    func setSuperProperties(_ properties: [String: AnalyticsValue]) {
        state.withLock { $0.append(.superProperties(properties)) }
    }

    func flush() async {}
}
