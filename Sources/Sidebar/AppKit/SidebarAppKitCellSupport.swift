import AppKit

@MainActor
enum SidebarAppKitCellMetrics {
    static let outerHorizontalInset: CGFloat = 6
    static let innerHorizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let minimumWorkspaceHeight: CGFloat = 36
    static let minimumGroupHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 6
    static let groupCornerRadius: CGFloat = 4
    static let accessorySide: CGFloat = 16
    static let groupAccessorySide: CGFloat = 14
    static let railWidth: CGFloat = 3
    static let maximumDetailLines = 6
}

@MainActor
enum SidebarAppKitCellText {
    static func bounded(
        _ value: String?,
        maximumCharacters: Int,
        maximumLines: Int
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed
            .split(whereSeparator: { $0.isNewline })
            .prefix(max(1, maximumLines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let flattened = lines.joined(separator: " ")
        guard flattened.count > maximumCharacters else { return flattened }
        return String(flattened.prefix(maximumCharacters))
    }

    static func joined(_ values: [String], maximumLines: Int) -> String? {
        let lines = values
            .compactMap { bounded($0, maximumCharacters: 1024, maximumLines: 1) }
            .prefix(maximumLines)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
