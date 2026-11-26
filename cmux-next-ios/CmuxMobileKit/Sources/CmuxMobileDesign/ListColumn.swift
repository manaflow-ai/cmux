#if os(iOS)
import SwiftUI
import UIKit

/// One text column per list (design/SPEC.md 4.2.1, "Lists: one text column").
///
/// A row's marks (status dots, disclosure chevrons, icons, small avatars,
/// spinners) hang in a leading gutter `mark` wide. The row's primary text
/// starts `gap` after it, at `text`. Section headers, footers, inline labels,
/// group titles and separators start at `text` too, so every title in a list
/// starts at one x.
///
/// `text` is measured from the row content's leading edge: the screen edge in
/// the plain lists (their rows have no leading inset), the cell's content
/// margin in the grouped lists (where the system header and footer text
/// start too).
public struct CmuxMobileListColumn: Equatable, Sendable {
    /// The gutter: the marks' column width.
    public var mark: CGFloat
    /// From the gutter to the text.
    public var gap: CGFloat

    public init(mark: CGFloat, gap: CGFloat) {
        self.mark = mark
        self.gap = gap
    }

    /// Where the primary text, headers, footers and separators start.
    public var text: CGFloat { mark + gap }

    /// The plain lists' gutter at Large (Workspaces): dots and chevrons centered in it.
    public static let plainGutter: CGFloat = 32
    /// The grouped lists' icon column at Large (Settings), and its gap to the text.
    public static let groupedIcon: CGFloat = 22
    public static let groupedGap: CGFloat = 14

    /// Plain lists: a 32 pt gutter at Large (scaling with the text), the text right after it.
    public static func plain(_ size: DynamicTypeSize) -> Self {
        Self(mark: scaled(plainGutter, size), gap: 0)
    }

    /// Grouped lists: a 22 pt icon column at Large, growing with the text up to
    /// twice that, then 14 pt to the text.
    public static func grouped(_ size: DynamicTypeSize) -> Self {
        Self(mark: min(scaled(groupedIcon, size), groupedIcon * 2), gap: groupedGap)
    }

    /// `value` at Large, scaled like `.body` for `size` (the curve the rows'
    /// text follows). Not `@ScaledMetric`: in list rows it scaled a 32 pt
    /// gutter to about 64 pt at Large (workspaces round 2 review).
    public static func scaled(_ value: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
        let category = UIContentSizeCategory(size)
        guard category != .large else { return value }
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: value, compatibleWith: traits)
    }
}

/// Which list family a header, footer or label sits in.
public enum CmuxMobileListKind: Sendable {
    /// `.plain` lists whose rows start at the screen edge (Workspaces).
    case plain
    /// `.insetGrouped` lists with Settings rows (an icon, then the title).
    case grouped
    /// Another column, fixed (a list with its own glyph size).
    case fixed(CmuxMobileListColumn)

    public func column(_ size: DynamicTypeSize) -> CmuxMobileListColumn {
        switch self {
        case .plain: .plain(size)
        case .grouped: .grouped(size)
        case .fixed(let column): column
        }
    }
}

extension View {
    /// Starts this plain-list section header or footer, inline label or
    /// icon-less row at the list's text column (the rows' titles), not in the
    /// marks' gutter. Grouped (Settings) headers and footers do not take it:
    /// they keep the system position, as in iOS Settings (SPEC 4.2.1).
    public func cmuxMobileTextColumn(_ kind: CmuxMobileListKind = .grouped) -> some View {
        modifier(CmuxMobileTextColumnModifier(kind: kind))
    }
}

private struct CmuxMobileTextColumnModifier: ViewModifier {
    let kind: CmuxMobileListKind
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.padding(.leading, kind.column(typeSize).text)
    }
}

/// A row with its mark in the gutter and its content at the text column.
/// The separator starts at the text.
public struct CmuxMobileGutterRow<Mark: View, Content: View>: View {
    let kind: CmuxMobileListKind
    let alignment: VerticalAlignment
    let mark: Mark
    let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ kind: CmuxMobileListKind = .grouped, alignment: VerticalAlignment = .center,
                @ViewBuilder mark: () -> Mark, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.alignment = alignment
        self.mark = mark()
        self.content = content()
    }

    public var body: some View {
        let column = kind.column(typeSize)
        HStack(alignment: alignment, spacing: column.gap) {
            // A mark wider than the gutter (a 28 pt avatar in the 22 pt
            // column) stays centered on it: the text keeps its x.
            mark.frame(width: column.mark)
            content
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}
#endif
