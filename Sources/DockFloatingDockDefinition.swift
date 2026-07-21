import CoreGraphics
import Foundation

struct DockFloatingDockDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let frame: DockFloatingDockFrameDefinition?
    let content: DockControlDefinition?

    init(
        id: String,
        title: String,
        frame: DockFloatingDockFrameDefinition? = nil,
        content: DockControlDefinition? = nil
    ) {
        self.id = id
        self.title = title
        self.frame = frame
        self.content = content
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case frame
        case content
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownDockConfigKeys(
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedID.isEmpty else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.blankFloatID",
                    defaultValue: "Floating Dock id must not be blank."
                )
            )
        }
        let decodedTitle = try container.decode(String.self, forKey: .title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedTitle.isEmpty else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.blankFloatTitle",
                    defaultValue: "Floating Dock title must not be blank."
                )
            )
        }

        id = decodedID
        title = decodedTitle
        frame = try container.decodeIfPresent(DockFloatingDockFrameDefinition.self, forKey: .frame)
        content = try container.decodeIfPresent(DockControlDefinition.self, forKey: .content)
    }

    func resolvedFrame(cascadeIndex: Int) -> CGRect {
        let cascade = Double(max(0, cascadeIndex) % 6) * 24
        return CGRect(
            x: frame?.x ?? 36 + cascade,
            y: frame?.y ?? 80 - cascade,
            width: frame?.width ?? 520,
            height: frame?.height ?? 380
        )
    }
}
