import Foundation

/// Layout constants of the menubar-sized surfaces.
enum ServerMetrics {
    static let panelWidth: CGFloat = 340
    static let dashboardWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 14
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
