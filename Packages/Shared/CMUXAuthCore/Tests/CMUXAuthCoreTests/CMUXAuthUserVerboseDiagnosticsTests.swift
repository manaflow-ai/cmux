import CMUXAuthCore
import Foundation
import Testing

/// The verbose-diagnostics activation gate: a server-written boolean on the
/// Stack account's `clientReadOnlyMetadata`, mirrored onto `CMUXAuthUser`
/// exactly like the demonstration-content flag. Only an explicit JSON `true`
/// activates it, unknown/legacy payloads fail closed, and persisted identity
/// cards from older builds decode as not-flagged.
@Suite("CMUXAuthUser verbose diagnostics")
struct CMUXAuthUserVerboseDiagnosticsTests {
    @Test("Metadata resolves only an explicit boolean true")
    func metadataResolvesOnlyExplicitBooleanTrue() {
        func resolve(_ metadata: [String: Any]?) -> Bool {
            CMUXAuthUser.verboseDiagnosticsEnabled(
                fromClientReadOnlyMetadata: metadata
            )
        }

        #expect(resolve(["cmuxVerboseDiagnostics": true]))
        #expect(!resolve(["cmuxVerboseDiagnostics": false]))
        #expect(!resolve(nil))
        #expect(!resolve([:]))
        #expect(!resolve(["cmuxPlan": "pro"]))
        // The sibling review flag never bleeds into this one.
        #expect(!resolve(["cmuxReviewDemoContent": true]))
        // Fail closed on every non-boolean shape a bad write could produce.
        #expect(!resolve(["cmuxVerboseDiagnostics": "true"]))
        #expect(!resolve(["cmuxVerboseDiagnostics": 1]))
        #expect(!resolve(["cmuxVerboseDiagnostics": 2.5]))
        #expect(!resolve(["cmuxVerboseDiagnostics": ["enabled": true]]))
        #expect(!resolve(["cmuxVerboseDiagnostics": NSNull()]))
    }

    @Test("Metadata parsed from real JSON activates the flag")
    func metadataParsedFromJSONActivates() throws {
        let payload = #"{"cmuxVerboseDiagnostics": true, "cmuxPlan": "pro"}"#
        let metadata = try JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        ) as? [String: Any]
        #expect(CMUXAuthUser.verboseDiagnosticsEnabled(
            fromClientReadOnlyMetadata: metadata
        ))

        let numericPayload = #"{"cmuxVerboseDiagnostics": 1}"#
        let numericMetadata = try JSONSerialization.jsonObject(
            with: Data(numericPayload.utf8)
        ) as? [String: Any]
        #expect(!CMUXAuthUser.verboseDiagnosticsEnabled(
            fromClientReadOnlyMetadata: numericMetadata
        ))
    }

    @Test("Identity cards persisted before the flag decode as not flagged")
    func legacyIdentityCardsDecodeAsNotFlagged() throws {
        let legacy = #"{"id": "user-1", "primaryEmail": "user@example.com"}"#
        let user = try JSONDecoder().decode(CMUXAuthUser.self, from: Data(legacy.utf8))
        #expect(!user.verboseDiagnosticsEnabled)
        #expect(user.id == "user-1")
    }

    @Test("The flag round-trips through the persisted identity card")
    func flagRoundTripsThroughCodable() throws {
        let flagged = CMUXAuthUser(
            id: "user-2",
            primaryEmail: "review@example.com",
            displayName: "Review",
            verboseDiagnosticsEnabled: true
        )
        let decoded = try JSONDecoder().decode(
            CMUXAuthUser.self,
            from: JSONEncoder().encode(flagged)
        )
        #expect(decoded == flagged)
        #expect(decoded.verboseDiagnosticsEnabled)
        #expect(!decoded.demonstrationContentEnabled)
    }

    @Test("Default construction is not flagged")
    func defaultConstructionIsNotFlagged() {
        let user = CMUXAuthUser(id: "user-3", primaryEmail: nil, displayName: nil)
        #expect(!user.verboseDiagnosticsEnabled)
    }
}
