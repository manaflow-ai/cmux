/// The vertical and metadata-type density used by transcript rows.
public enum TranscriptDensity: String, CaseIterable, Sendable {
    /// The default register, optimized for relaxed reading rhythm.
    case comfortable
    /// A tighter register that compresses transcript chrome without shrinking prose.
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
