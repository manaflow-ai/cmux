#if DEBUG
import SwiftUI

/// Scales Phosphor's exact base type roles with Dynamic Type, excluding terminal text.
struct PhosphorTypography: DynamicProperty {
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var dataSize: CGFloat = 13

    var title: Font { .system(size: titleSize, weight: .semibold) }
    var body: Font { .system(size: bodySize, weight: .regular) }
    var bodySemibold: Font { .system(size: bodySize, weight: .semibold) }
    var caption: Font { .system(size: captionSize, weight: .regular) }
    var captionSemibold: Font { .system(size: captionSize, weight: .semibold) }
    var data: Font { .system(size: dataSize, weight: .regular, design: .monospaced) }
    var dataMedium: Font { .system(size: dataSize, weight: .medium, design: .monospaced) }
    var dataSemibold: Font { .system(size: dataSize, weight: .semibold, design: .monospaced) }
    var monoCaption: Font { .system(size: captionSize, weight: .regular, design: .monospaced) }
    var monoCaptionMedium: Font { .system(size: captionSize, weight: .medium, design: .monospaced) }
    var terminal: Font { .system(size: 12, weight: .regular, design: .monospaced) }
}
#endif
