import Foundation

/// The immutable identifier tmux assigns for the lifetime of one session.
struct LocalTmuxSessionIdentity: Equatable, Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        let bytes = rawValue.utf8
        guard bytes.count >= 2,
              bytes.first == 0x24,
              bytes.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}
