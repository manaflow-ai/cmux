import Foundation

/// Text value rendered by a sidebar provider row.
public enum CmuxSidebarProviderText: Codable, Equatable, Sendable {
    /// Plain, already-localized text.
    case plain(String)
    /// String catalog backed text.
    case localized(CmuxSidebarProviderLocalizedText)
    /// Relative date text rendered against the current render context.
    case relativeDate(Date, style: CmuxSidebarProviderRelativeDateStyle)

    /// Date carried by relative-date text, if any.
    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}
