import CoreGraphics
import Foundation

struct DockFloatingDockFrameDefinition: Codable, Equatable, Sendable {
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?

    init(
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownDockConfigKeys(
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)

        guard width.map({ $0 >= 320 }) ?? true,
              height.map({ $0 >= 220 }) ?? true else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.floatFrameMinimum",
                    defaultValue: "Floating Dock frames must be at least 320 points wide and 220 points tall."
                )
            )
        }
    }
}
