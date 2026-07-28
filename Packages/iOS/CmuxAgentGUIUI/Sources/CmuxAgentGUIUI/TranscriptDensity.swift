/// The vertical and metadata-type density used by transcript rows.
public enum TranscriptDensity: String, CaseIterable, Sendable {
    /// A relaxed reading rhythm available when extra vertical space is preferred.
    case comfortable
    /// The default register, compressing transcript chrome without shrinking prose.
    case compact
}

#if os(iOS)
import SwiftUI

extension TranscriptDensity {
    var metadataFont: Font {
        switch self {
        case .comfortable: .footnote
        case .compact: .caption
        }
    }
}
#endif
