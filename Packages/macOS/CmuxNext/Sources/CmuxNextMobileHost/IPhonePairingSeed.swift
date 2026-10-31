public import CmuxNextMobile
public import Foundation

/// Test-only, DEBUG builds only: phones a tagged test instance trusts without its
/// person-only "Allow … to connect?" prompt, so a hidden rig app can pair a simulator
/// (cmux-next-ios/SECURITY.md "Test-only pairing seed"). The app reads
/// `CMUX_NEXT_IPHONE_PAIRING_SEED` once at launch; a Release build compiles none of
/// this and ignores the variable. The file is read when a phone asks, so a rig can
/// write it after the app started:
///
/// ```json
/// {"devices": [{"id": "<phone link device id>", "name": "<phone name>",
///               "identityKey": "04…", "approvalKey": "04…"}]}
/// ```
///
/// An entry matches a request when every field it gives matches (`id` or `name`,
/// and the keys when given); an empty entry matches nothing.
public nonisolated struct IPhonePairingSeed: Sendable, Equatable {
    public static let environmentKey = "CMUX_NEXT_IPHONE_PAIRING_SEED"
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The seed of this launch's environment; nil in a Release build or without the variable.
    public static func fromEnvironment(_ environment: [String: String]) -> IPhonePairingSeed? {
        #if DEBUG
        guard let path = environment[environmentKey], path.hasPrefix("/") else { return nil }
        return IPhonePairingSeed(file: URL(fileURLWithPath: path))
        #else
        return nil
        #endif
    }

    nonisolated struct Entry: Decodable {
        var id: String?
        var name: String?
        var identityKey: String?
        var approvalKey: String?

        func matches(_ request: MobileHostPairRequest) -> Bool {
            guard id != nil || name != nil else { return false }
            return (id.map { $0.lowercased() == request.phoneDeviceID.lowercased() } ?? true)
                && (name.map { $0 == request.name } ?? true)
                && (identityKey.map { $0.lowercased() == request.identityKey } ?? true)
                && (approvalKey.map { $0.lowercased() == request.approvalKey } ?? true)
        }
    }

    nonisolated struct File: Decodable {
        var devices: [Entry]
    }

    /// Whether the seed trusts `request` now (an unreadable file trusts nothing).
    public func trusts(_ request: MobileHostPairRequest) -> Bool {
        guard let data = try? Data(contentsOf: file), let seed = try? JSONDecoder().decode(File.self, from: data) else {
            return false
        }
        return seed.devices.contains { $0.matches(request) }
    }
}
