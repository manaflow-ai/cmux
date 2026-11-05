import Foundation
import CmuxNextDesign

/// Layout constants of the menubar-sized surfaces.
enum ServerMetrics {
    static let panelWidth: CGFloat = 340
    static let dashboardWidth: CGFloat = 360
    static var cornerRadius: CGFloat { Metrics.surfaceCornerRadius }
    static var cardRadius: CGFloat { Metrics.insetCornerRadius }
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 14
    /// The Add Server card.
    static let cardWidth: CGFloat = 380
    static let codeFieldHeight: CGFloat = 44
    static let rowFieldHeight: CGFloat = 28
    static var fieldRadius: CGFloat { Metrics.controlCornerRadius }
    static let chipHeight: CGFloat = 26
    static let spinnerSize: CGFloat = 12
    static let factsIconSize: CGFloat = 18
    static let factsIconWidth: CGFloat = 28
    static let successIconSize: CGFloat = 32
    static let bannerFillOpacity: CGFloat = 0.12
}

/// Date and size text (absolute times: nothing on screen counts down, so
/// nothing needs a timer).
enum ServerFormat {
    static func time(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
