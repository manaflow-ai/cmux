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
/// and the keys when given); an empty entry matches nothing. The match is Rust's.
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

    /// Whether the seed trusts `request` now (an unreadable file trusts nothing). The match is Rust's
    /// (`cmux-mobile-host-core` `pairing_seed`, the app FFI's `mobile_host` op `pairing_seed_trusts`).
    public func trusts(_ request: MobileHostPairRequest) -> Bool {
        var fields: [String: Any] = [
            "request": ["phoneDeviceId": request.phoneDeviceID, "name": request.name, "identityKey": request.identityKey,
                        "approvalKey": request.approvalKey],
        ]
        fields["seed"] = (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
        return MobileHostRules.ask("pairing_seed_trusts", fields)?["trusts"] as? Bool ?? false
    }
}
