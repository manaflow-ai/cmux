import Foundation

extension DevBackendStartup {
    struct Status: Decodable, Equatable {
        let state: String
        let message: String
        var isFailure: Bool { state == "failed" }
        var isReady: Bool { state == "ready" }
    }
}
