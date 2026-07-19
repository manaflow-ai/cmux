#if DEBUG
import Foundation

struct MobileIrohReleaseGateArtifactPreparation: Equatable, Sendable {
    static let requiredStableStatObservations = 1

    let path: String
    let suffixText: String
    let completionMarker: String
    let command: String

    static func make(
        path: String,
        suffixText: String,
        marker: String
    ) -> MobileIrohReleaseGateArtifactPreparation {
        MobileIrohReleaseGateArtifactPreparation(
            path: path,
            suffixText: suffixText,
            completionMarker: path,
            command: "dd if=/dev/zero of='\(path)' bs=1048576 count=32 2>/dev/null; "
                + "printf '%s' '\(suffixText)' >> '\(path)'; "
                + "printf '\\n%s\\n' '\(path)'\n"
        )
    }
}
#endif
