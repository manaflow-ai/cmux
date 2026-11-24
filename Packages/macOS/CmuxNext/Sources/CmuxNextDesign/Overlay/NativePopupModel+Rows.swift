import Foundation

extension NativePopupModel {
    /// Every top-level row the popup draws, in order: the rail, the search row's accessory, the
    /// rows, each column's rows, then the footer. Events, focus and validation read this one list.
    var allRows: [NativePopupRow] {
        (rail ?? []) + (searchAccessory.map { [$0] } ?? []) + rows + (columns ?? []).flatMap(\.rows) + (footer ?? [])
    }

    /// The model with `transform` applied to each list of top-level rows.
    func mappingRows(_ transform: ([NativePopupRow]) -> [NativePopupRow]) -> NativePopupModel {
        var next = self
        next.rows = transform(rows)
        next.rail = rail.map(transform)
        next.footer = footer.map(transform)
        next.searchAccessory = searchAccessory.flatMap { transform([$0]).first }
        next.columns = columns?.map { column in
            var column = column
            column.rows = transform(column.rows)
            return column
        }
        return next
    }

    /// The popup lays out as columns.
    var hasColumns: Bool { columns?.isEmpty == false }
}
