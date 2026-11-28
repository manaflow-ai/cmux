import CMUXAuthCore
import Foundation
import Testing

/// The demonstration-content activation gate: a server-written boolean on the
/// Stack account's `clientReadOnlyMetadata`, mirrored onto `CMUXAuthUser`.
/// Only an explicit JSON `true` activates it, unknown/legacy payloads fail
/// closed, and persisted identity cards from older builds decode as
/// not-flagged.
@Suite("CMUXAuthUser demonstration content")
struct CMUXAuthUserDemonstrationContentTests {
    @Test("Metadata resolves only an explicit boolean true")
    func metadataResolvesOnlyExplicitBooleanTrue() {
        func resolve(_ metadata: [String: Any]?) -> Bool {
            CMUXAuthUser.demonstrationContentEnabled(
                fromClientReadOnlyMetadata: metadata
            )
        }

        #expect(resolve(["cmuxReviewDemoContent": true]))
        #expect(!resolve(["cmuxReviewDemoContent": false]))
        #expect(!resolve(nil))
        #expect(!resolve([:]))
        #expect(!resolve(["cmuxPlan": "pro"]))
        // Fail closed on every non-boolean shape a bad write could produce.
        #expect(!resolve(["cmuxReviewDemoContent": "true"]))
        #expect(!resolve(["cmuxReviewDemoContent": 1]))
        #expect(!resolve(["cmuxReviewDemoContent": 2.5]))
        #expect(!resolve(["cmuxReviewDemoContent": ["enabled": true]]))
        #expect(!resolve(["cmuxReviewDemoContent": NSNull()]))
    }

    @Test("Metadata parsed from real JSON activates the flag")
    func metadataParsedFromJSONActivates() throws {
        let payload = #"{"cmuxReviewDemoContent": true, "cmuxPlan": "pro"}"#
        let metadata = try JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        ) as? [String: Any]
        #expect(CMUXAuthUser.demonstrationContentEnabled(
            fromClientReadOnlyMetadata: metadata
        ))

        let numericPayload = #"{"cmuxReviewDemoContent": 1}"#
        let numericMetadata = try JSONSerialization.jsonObject(
            with: Data(numericPayload.utf8)
        ) as? [String: Any]
        #expect(!CMUXAuthUser.demonstrationContentEnabled(
            fromClientReadOnlyMetadata: numericMetadata
        ))
    }

    @Test("Identity cards persisted before the flag decode as not flagged")
    func legacyIdentityCardsDecodeAsNotFlagged() throws {
        let legacy = #"{"id": "user-1", "primaryEmail": "user@example.com"}"#
        let user = try JSONDecoder().decode(CMUXAuthUser.self, from: Data(legacy.utf8))
        #expect(!user.demonstrationContentEnabled)
        #expect(user.id == "user-1")
    }

    @Test("The flag round-trips through the persisted identity card")
    func flagRoundTripsThroughCodable() throws {
        let flagged = CMUXAuthUser(
            id: "user-2",
            primaryEmail: "review@example.com",
            displayName: "Review",
            demonstrationContentEnabled: true
        )
        let decoded = try JSONDecoder().decode(
            CMUXAuthUser.self,
            from: JSONEncoder().encode(flagged)
        )
        #expect(decoded == flagged)
        #expect(decoded.demonstrationContentEnabled)
    }

    @Test("Default construction is not flagged")
    func defaultConstructionIsNotFlagged() {
        let user = CMUXAuthUser(id: "user-3", primaryEmail: nil, displayName: nil)
        #expect(!user.demonstrationContentEnabled)
    }
}
