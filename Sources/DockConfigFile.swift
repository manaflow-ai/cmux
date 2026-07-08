import Foundation

struct DockConfigFile: Codable, Sendable {
    static let maximumControlCount = 64

    let controls: [DockControlDefinition]

    private enum CodingKeys: String, CodingKey {
        case controls
    }

    init(controls: [DockControlDefinition]) {
        self.controls = controls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let controls = try container.decode([DockControlDefinition].self, forKey: .controls)
        guard controls.count <= Self.maximumControlCount else {
            throw Self.validationError(
                code: 8,
                message: String(
                    format: String(
                        localized: "dock.error.tooManyControls",
                        defaultValue: "Dock config supports at most %lld controls."
                    ),
                    Int64(Self.maximumControlCount)
                )
            )
        }
        self.controls = controls
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(controls, forKey: .controls)
    }

    private static func validationError(code: Int, message: String) -> NSError {
        NSError(
            domain: "cmux.dock",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
