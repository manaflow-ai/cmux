import Foundation

struct SimulatorWebInspectorIncomingResult: Equatable {
    var messagesForHost: [Data] = []
    var messagesForTarget: [Data] = []
}
