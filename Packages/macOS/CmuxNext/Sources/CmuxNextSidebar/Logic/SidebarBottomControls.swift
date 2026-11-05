public import CmuxNextDesign
public import CoreGraphics

/// Prototype looks for the sidebar's bottom-left corner (Debug Settings `sidebar.bottomControls`): the
/// profile avatar and the Search button, drawn as larger hit targets. Leo 2026-11-05, on the comfortable
/// sidebar's footer: "who wants to click on circles that small these days"; the spaces strip in the middle
/// stays as it is ("I guess that one's actually fine"). `.standard` is the shipped footer, and every
/// other look applies only off the compact density (Lawrence's dense sidebar keeps its footer).
public nonisolated enum SidebarBottomControlsVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The shipped footer: a 16 pt avatar in its tile, a row-height Search square.
    case standard
    /// One line, the avatar and Search as 32 pt targets (28 at the smallest), Search on the +'s column.
    case largeTargets
    /// A wide Search field across the bottom over the avatar and spaces line.
    case searchField
    /// The avatar becomes a named account row at the very bottom; the spaces and Search sit above it.
    case accountRow
    /// The bottom line mirrors the titlebar line: the +'s button size and column, the same distance
    /// from the edge, so the sidebar's top and bottom read as a pair.
    case mirrored

    public var tunableTitle: String {
        switch self {
        case .standard: "Standard (shipped)"
        case .largeTargets: "Large targets"
        case .searchField: "Wide Search field"
        case .accountRow: "Named account row"
        case .mirrored: "Mirror the top cluster"
        }
    }

    /// The look adds a second line to the footer.
    var addsLine: Bool { self == .searchField || self == .accountRow }
}

extension SidebarTunables {
    /// Debug Settings `sidebar.bottomControls` (``SidebarBottomControlsVariant``).
    public nonisolated static let bottomControls = Tunable<SidebarBottomControlsVariant>.choice(
        "sidebar.bottomControls", .sidebar, "Bottom-left controls",
        help: "Prototype for the sidebar's bottom-left corner off the compact density: larger avatar and Search targets, a wide Search field, a named account row, or a bottom line that mirrors the titlebar line.",
        default: .standard, code: "SidebarTunables.bottomControls")
}

/// The pure geometry of the bottom controls (``SidebarBottomControlsVariant``), in the sidebar's flipped
/// coordinates: tests pin it without a window.
public nonisolated struct SidebarBottomControlsGeometry: Equatable, Sendable {
    /// The avatar control (a square whose circle is truly round), nil when the look draws none.
    public var avatar: CGRect?
    /// The Search button (square), nil when the look shows Search as a field.
    public var search: CGRect?
    /// The wide Search field.
    public var searchField: CGRect?
    /// The named account row.
    public var accountRow: CGRect?
    /// Where the spaces strip runs: its frame (the strip centers on the sidebar inside it).
    public var spaces: CGRect

    /// The hit side every look's square targets get: 32 pt, never under 28 (Apple's HIG minimum for a
    /// pointer target is 28 pt on macOS), never past the line it sits on plus the room the look adds.
    public static func targetSide(rowHeight: CGFloat) -> CGFloat { min(32, max(28, rowHeight)) }

    /// The extra footer height the look needs above the band's first line.
    public static func extraHeight(_ variant: SidebarBottomControlsVariant, rowHeight: CGFloat, gap: CGFloat) -> CGFloat {
        variant.addsLine ? targetSide(rowHeight: rowHeight) + gap : 0
    }

    /// - Parameters:
    ///   - width: the sidebar's width.
    ///   - column: the + (New Workspace) button's center x: Search shares it, so the top and bottom
    ///     trailing controls stand on one column.
    ///   - line: the band's first line (the avatar's row), where the spaces strip runs.
    ///   - upper: the line the look adds above it (`footer.frame`), zero height when it adds none.
    ///   - topButtonSide: the titlebar +'s side (``mirrored``).
    ///   - scale: the backing scale, for pixel-aligned frames.
    public static func layout(_ variant: SidebarBottomControlsVariant, width: CGFloat, column: CGFloat,
                              line: CGRect, upper: CGRect, topButtonSide: CGFloat, scale: CGFloat) -> SidebarBottomControlsGeometry {
        let side = variant == .mirrored ? max(28, topButtonSide) : targetSide(rowHeight: line.height)
        // The leading control mirrors the trailing one: its center is as far from the leading edge
        // as Search's is from the trailing edge.
        let leadCenter = width - column
        func square(_ centerX: CGFloat, _ centerY: CGFloat) -> CGRect {
            pixel(CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side), scale)
        }
        // The span between the two columns' outer edges: a field or row lines up with both squares.
        let spanMinX = leadCenter - side / 2, spanMaxX = column + side / 2
        func span(_ centerY: CGFloat) -> CGRect {
            pixel(CGRect(x: spanMinX, y: centerY - side / 2, width: spanMaxX - spanMinX, height: side), scale)
        }
        func strip(between lead: CGRect?, and trail: CGRect?, on y: CGRect) -> CGRect {
            let minX = (lead?.maxX ?? 0), maxX = trail?.minX ?? width
            return CGRect(x: minX, y: y.minY, width: max(0, maxX - minX), height: y.height)
        }
        switch variant {
        case .standard:
            return SidebarBottomControlsGeometry(avatar: nil, search: nil, searchField: nil, accountRow: nil, spaces: line)
        case .largeTargets, .mirrored:
            let avatar = square(leadCenter, line.midY), search = square(column, line.midY)
            return SidebarBottomControlsGeometry(avatar: avatar, search: search, searchField: nil, accountRow: nil,
                                                 spaces: strip(between: avatar, and: search, on: line))
        case .searchField:
            let avatar = square(leadCenter, line.midY)
            return SidebarBottomControlsGeometry(avatar: avatar, search: nil, searchField: span(upper.midY), accountRow: nil,
                                                 spaces: strip(between: avatar, and: nil, on: line))
        case .accountRow:
            // The account row takes the corner (as Slack, Linear and ChatGPT put the account); the
            // spaces strip and Search move up to the added line.
            let search = square(column, upper.midY)
            let spacesLine = CGRect(x: 0, y: upper.minY, width: width, height: upper.height)
            return SidebarBottomControlsGeometry(avatar: nil, search: search, searchField: nil, accountRow: span(line.midY),
                                                 spaces: strip(between: nil, and: search, on: spacesLine))
        }
    }

    static func pixel(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        let s = max(1, scale)
        return CGRect(x: (rect.minX * s).rounded() / s, y: (rect.minY * s).rounded() / s,
                      width: (rect.width * s).rounded() / s, height: (rect.height * s).rounded() / s)
    }
}
