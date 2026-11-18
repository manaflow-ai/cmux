import Foundation

/// NativePopupModel on the native popup wire.
public struct NativePopupModel: Codable, Equatable, Sendable {
    public var `schemaVersion`: Int
    public var `id`: String
    public var `revision`: Int
    public var `anchor`: NativePopupAnchor
    public var `side`: NativePopupSide
    public var `align`: NativePopupAlign
    public var `width`: Double
    public var `rows`: [NativePopupRow]
    public var `parentId`: String?
    public var `title`: String?
    public var `search`: NativePopupField?
    public var `highlighted`: String?
    public var `rail`: [NativePopupRow]?
    public var `railWidth`: Double?
    public var `railPlacement`: NativePopupRailPlacement?
    public var `footer`: [NativePopupRow]?
    /// Columns side by side under the search row (and under `rows`, which span the popup).
    public var `columns`: [NativePopupColumn]?
    /// The columns' band is at most this tall; a longer column scrolls.
    public var `columnsHeight`: Double?
    /// A control at the search row's leading edge, drawn as its mark (the picker's account
    /// avatar). A submenu: a click opens its children beside the popup.
    public var `searchAccessory`: NativePopupRow?

    public init(schemaVersion: Int, id: String, revision: Int, anchor: NativePopupAnchor, side: NativePopupSide, align: NativePopupAlign, width: Double, rows: [NativePopupRow], parentId: String? = nil, title: String? = nil, search: NativePopupField? = nil, highlighted: String? = nil, rail: [NativePopupRow]? = nil, railWidth: Double? = nil, railPlacement: NativePopupRailPlacement? = nil, footer: [NativePopupRow]? = nil, columns: [NativePopupColumn]? = nil, columnsHeight: Double? = nil, searchAccessory: NativePopupRow? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.anchor = anchor
        self.side = side
        self.align = align
        self.width = width
        self.rows = rows
        self.parentId = parentId
        self.title = title
        self.search = search
        self.highlighted = highlighted
        self.rail = rail
        self.railWidth = railWidth
        self.railPlacement = railPlacement
        self.footer = footer
        self.columns = columns
        self.columnsHeight = columnsHeight
        self.searchAccessory = searchAccessory
    }
}
