import Foundation

nonisolated struct RustBaseY: Encodable {
    var displayY: Double; var gapY: Double?; var gapHeight: Double
    enum CodingKeys: String, CodingKey { case displayY = "display_y"; case gapY = "gap_y"; case gapHeight = "gap_height" }
}
