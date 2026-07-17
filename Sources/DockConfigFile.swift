import Foundation

struct DockConfigFile: Codable, Sendable {
    let controls: [DockControlDefinition]
    let floats: [DockFloatingDockDefinition]

    init(
        controls: [DockControlDefinition] = [],
        floats: [DockFloatingDockDefinition] = []
    ) {
        self.controls = controls
        self.floats = floats
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case controls
        case floats
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownDockConfigKeys(
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.controls) {
            controls = try container.decode([DockControlDefinition].self, forKey: .controls)
        } else {
            controls = []
        }
        if container.contains(.floats) {
            floats = try container.decode([DockFloatingDockDefinition].self, forKey: .floats)
        } else {
            floats = []
        }
        try validateSchema()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(controls, forKey: .controls)
        if !floats.isEmpty {
            try container.encode(floats, forKey: .floats)
        }
    }

    func validate(isProjectSource: Bool) throws {
        try validateSchema()
        guard isProjectSource || floats.isEmpty else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.globalFloatsUnsupported",
                    defaultValue: "Floating Docks are supported only in project .cmux/dock.json files."
                )
            )
        }
    }

    private func validateSchema() throws {
        var controlIDs = Set<String>()
        guard controls.allSatisfy({ controlIDs.insert($0.id).inserted }) else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.duplicateControl",
                    defaultValue: "Dock control ids must be unique."
                )
            )
        }
        guard controls.allSatisfy({ $0.kind != .note }) else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.unknownControlType",
                    defaultValue: "Dock control type must be terminal or browser."
                )
            )
        }

        var floatIDs = Set<String>()
        guard floats.allSatisfy({ floatIDs.insert($0.id).inserted }) else {
            throw DockConfigValidationError(
                message: String(
                    localized: "dock.error.duplicateFloat",
                    defaultValue: "Floating Dock ids must be unique."
                )
            )
        }
    }
}
