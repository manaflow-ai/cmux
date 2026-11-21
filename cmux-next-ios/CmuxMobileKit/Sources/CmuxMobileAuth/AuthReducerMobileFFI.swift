#if os(iOS)
import CmuxAuthRuntime
import Foundation
import CmuxMobileLinkFFI

/// The Rust auth reducer through the phone's UniFFI object
/// (`CmuxMobileLinkFFI.AuthCoordinator`). ``CmuxAuthRuntime/AuthCoordinator``
/// uses it on the main actor only.
public final class AuthReducerMobileFFI: AuthReducerEngine {
    struct NotUTF8: Error {}

    private let reducer: CmuxMobileLinkFFI.AuthCoordinator

    /// The factory ``CmuxAuthRuntime/AuthCoordinator`` takes.
    public static let factory: AuthReducerFactory = { try AuthReducerMobileFFI(config: $0) }

    public init(config: Data) throws {
        guard let json = String(data: config, encoding: .utf8) else { throw NotUTF8() }
        reducer = try CmuxMobileLinkFFI.AuthCoordinator(configJson: json)
    }

    public func feed(_ event: Data) throws {
        guard let json = String(data: event, encoding: .utf8) else { throw NotUTF8() }
        try reducer.feed(eventJson: json)
    }

    public func takeEffects() -> Data { Data(reducer.takeEffects().utf8) }

    public func snapshot() -> Data { Data(reducer.snapshot().utf8) }
}
#endif
