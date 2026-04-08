import Foundation

enum UpdateTiming {
    struct Values {
        let minimumCheckDisplayDuration: TimeInterval
        let noUpdateDisplayDuration: TimeInterval
        let checkTimeoutDuration: TimeInterval

        static let live = Values(
            minimumCheckDisplayDuration: 2.0,
            noUpdateDisplayDuration: 5.0,
            checkTimeoutDuration: 10.0
        )
    }

    static let minimumCheckDisplayDuration = Values.live.minimumCheckDisplayDuration
    static let noUpdateDisplayDuration = Values.live.noUpdateDisplayDuration
    static let checkTimeoutDuration = Values.live.checkTimeoutDuration
}
