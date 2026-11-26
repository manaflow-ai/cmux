import Foundation

public extension CloudTuiRequests {
    /// Updates one durable Cloud display-membership projection.
    static func putCloudDisplayMembershipProjection(
        projectionID: String,
        frontendID: String,
        windowID: String,
        generation: String,
        projection: [String: Any],
        expectedProjectionRevision: UInt64?,
        idempotencyKey: String
    ) -> CloudTuiRequest {
        var fields: [String: Any] = [
            "frontend_projection": projectionID,
            "frontend_id": frontendID,
            "window_id": windowID,
            "generation": generation,
            "projection": projection,
        ]
        if let expectedProjectionRevision {
            fields["expected_projection_revision"] = String(expectedProjectionRevision)
        }
        return CloudTuiRequest("frontend_projection.put", fields, mutation: true, key: idempotencyKey)
    }
}
