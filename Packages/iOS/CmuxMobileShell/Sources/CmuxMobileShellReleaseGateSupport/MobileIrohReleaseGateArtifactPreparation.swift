#if DEBUG
import Foundation

struct MobileIrohReleaseGateArtifactPreparation: Equatable, Sendable {
    static let requiredStableStatObservations = 2

    let path: String
    let suffixText: String
    let completionMarker: String
    let command: String

    static func make(
        path: String,
        suffixText: String,
        marker: String
    ) -> MobileIrohReleaseGateArtifactPreparation {
        let completionPrefix = "CMUX_IROH_ARTIFACT_READY_"
        let completionNonce = String(marker.suffix(24))
        return MobileIrohReleaseGateArtifactPreparation(
            path: path,
            suffixText: suffixText,
            completionMarker: completionPrefix + completionNonce,
            command: "dd if=/dev/zero of='\(path)' bs=1048576 count=32 2>/dev/null; "
                + "printf '%s' '\(suffixText)' >> '\(path)'; "
                + "printf '\\n%s\\n' '\(path)'; "
                + "printf '\\n%s%s\\n' '\(completionPrefix)' '\(completionNonce)'\n"
        )
    }
}
#endif
