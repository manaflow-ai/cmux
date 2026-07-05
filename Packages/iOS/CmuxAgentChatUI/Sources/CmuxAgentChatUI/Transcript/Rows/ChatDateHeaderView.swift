import SwiftUI

/// A centered day-boundary pill ("Today", "Yesterday", "Jun 9, 2026")
/// rendered between transcript messages from different days.
public struct ChatDateHeaderView: View {
    private let day: Date

    /// Creates a date header.
    ///
    /// - Parameter day: Any instant within the day the header labels.
    public init(day: Date) {
        self.day = day
    }

    public var body: some View {
        Text(Self.label(for: day))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityIdentifier("ChatDateHeader")
    }

    /// Formats `day` as a relative day name ("Today"/"Yesterday") when the
    /// locale supports it, otherwise as a medium date. The formatter
    /// localizes the result; no string catalog entry is needed.
    private static func label(for day: Date) -> String {
        relativeDayFormatter.string(from: day)
    }

    /// Shared formatter: creating a `DateFormatter` per render inside the
    /// lazy transcript is measurable scroll cost. Recreated implicitly on
    /// app relaunch, which bounds locale staleness in practice.
    private static let relativeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
