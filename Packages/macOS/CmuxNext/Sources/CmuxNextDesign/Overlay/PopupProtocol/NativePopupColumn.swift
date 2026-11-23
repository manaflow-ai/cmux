import Foundation

/// NativePopupColumn on the native popup wire: one column of a popup laid out as columns (the
/// model picker's harness rail, its models, then the shown model's effort and Fast), side by side
/// under the search row. Each column scrolls on its own.
public struct NativePopupColumn: Codable, Equatable, Sendable {
    public var `id`: String
    /// The column's accessible name.
    public var `label`: String
    /// Points wide; absent on the last column, which takes what is left of the popup's width.
    public var `width`: Double?
    /// The rows draw as a narrow rail of marks (`mark`, `monogram` or `icon`), the checked one lit.
    public var `rail`: Bool?
    public var `rows`: [NativePopupRow]

    public init(id: String, label: String, width: Double? = nil, rail: Bool? = nil, rows: [NativePopupRow]) {
        self.id = id
        self.label = label
        self.width = width
        self.rail = rail
        self.rows = rows
    }
}
