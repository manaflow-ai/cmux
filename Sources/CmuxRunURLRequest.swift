import Foundation

enum CmuxRunURLParseError: Error, Equatable {
    case unsupportedURLShape
    case missingParameter(String)
    case emptyParameter(String)
    case valueTooLong(parameter: String, maxLength: Int)
    case unsafeCharacters(String)
    case duplicateParameter(String)
    case unsupportedParameter(String)
    case invalidPlacement(String)
    case invalidDirection(String)
    case invalidIdentifier(String)
    case invalidTargetCombination
    case multipleLinks
}

/// A strictly parsed request to run one reviewed shell command in a new terminal.
///
/// The request cannot reuse an existing terminal, inject input, set environment
/// variables, run in the background, or suppress focus. Those omissions keep the
/// approval dialog's execution plan complete and reviewable.
struct CmuxRunURLRequest: Equatable {
    enum Placement: String, Equatable {
        case workspace
        case surface
        case pane
    }

    enum Anchor: Equatable {
        case pane(UUID)
        case surface(UUID)
    }

    enum Direction: String, Equatable {
        case left
        case right
        case up
        case down
    }

    static let maxCommandLength = 8_000
    static let maxWorkingDirectoryLength = 4_096
    static var activeSupportedSchemes: Set<String> {
        CmuxSSHURLRequest.activeSupportedSchemes
    }

    let originalURL: URL
    let command: String
    let workingDirectory: String
    let placement: Placement
    let workspaceId: UUID?
    let anchor: Anchor?
    let direction: Direction?

    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxRunURLRequest?, CmuxRunURLParseError> {
        guard let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme) else {
            return .success(nil)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedURLShape)
        }
        guard components.host?.lowercased() == "run" else {
            return .success(nil)
        }
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedFragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return .failure(.unsupportedURLShape)
        }

        let queryItems = components.queryItems ?? []
        let allowedNames: Set<String> = [
            "command", "cwd", "placement", "workspace", "pane", "surface", "direction"
        ]
        var values: [String: String?] = [:]
        var seenNames = Set<String>()
        for item in queryItems {
            let name = item.name.lowercased()
            guard allowedNames.contains(name) else {
                return .failure(.unsupportedParameter(displayParameterName(item.name)))
            }
            guard seenNames.insert(name).inserted else {
                return .failure(.duplicateParameter(displayParameterName(item.name)))
            }
            values.updateValue(item.value, forKey: name)
        }

        guard let rawCommand = values["command"] ?? nil else {
            return .failure(.missingParameter("command"))
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .failure(.emptyParameter("command"))
        }
        guard command.utf8.count <= maxCommandLength else {
            return .failure(.valueTooLong(parameter: "command", maxLength: maxCommandLength))
        }
        guard !containsUnsafeCommandCharacter(command) else {
            return .failure(.unsafeCharacters("command"))
        }

        guard let workingDirectory = values["cwd"] ?? nil else {
            return .failure(.missingParameter("cwd"))
        }
        guard !workingDirectory.isEmpty else {
            return .failure(.emptyParameter("cwd"))
        }
        guard workingDirectory.utf8.count <= maxWorkingDirectoryLength else {
            return .failure(
                .valueTooLong(parameter: "cwd", maxLength: maxWorkingDirectoryLength)
            )
        }
        guard !containsUnsafeHiddenCharacter(workingDirectory) else {
            return .failure(.unsafeCharacters("cwd"))
        }

        let placementRaw = (values["placement"] ?? nil) ?? Placement.workspace.rawValue
        guard let placement = Placement(rawValue: placementRaw.lowercased()) else {
            return .failure(.invalidPlacement("placement"))
        }

        let workspaceResult = parsedUUID(values["workspace"] ?? nil, parameter: "workspace")
        let paneResult = parsedUUID(values["pane"] ?? nil, parameter: "pane")
        let surfaceResult = parsedUUID(values["surface"] ?? nil, parameter: "surface")
        let workspaceId: UUID?
        let paneId: UUID?
        let surfaceId: UUID?
        switch workspaceResult {
        case .success(let value): workspaceId = value
        case .failure(let error): return .failure(error)
        }
        switch paneResult {
        case .success(let value): paneId = value
        case .failure(let error): return .failure(error)
        }
        switch surfaceResult {
        case .success(let value): surfaceId = value
        case .failure(let error): return .failure(error)
        }

        let direction: Direction?
        if let rawDirection = values["direction"] ?? nil {
            guard let parsed = Direction(rawValue: rawDirection.lowercased()) else {
                return .failure(.invalidDirection("direction"))
            }
            direction = parsed
        } else {
            direction = nil
        }

        switch placement {
        case .workspace:
            guard workspaceId == nil, paneId == nil, surfaceId == nil, direction == nil else {
                return .failure(.invalidTargetCombination)
            }
            return .success(
                CmuxRunURLRequest(
                    originalURL: url,
                    command: command,
                    workingDirectory: workingDirectory,
                    placement: placement,
                    workspaceId: nil,
                    anchor: nil,
                    direction: nil
                )
            )

        case .surface, .pane:
            guard let workspaceId, (paneId == nil) != (surfaceId == nil) else {
                return .failure(.invalidTargetCombination)
            }
            if placement == .surface, direction != nil {
                return .failure(.invalidTargetCombination)
            }
            if placement == .pane, direction == nil {
                return .failure(.missingParameter("direction"))
            }
            let anchor = paneId.map(Anchor.pane) ?? surfaceId.map(Anchor.surface)
            return .success(
                CmuxRunURLRequest(
                    originalURL: url,
                    command: command,
                    workingDirectory: workingDirectory,
                    placement: placement,
                    workspaceId: workspaceId,
                    anchor: anchor,
                    direction: direction
                )
            )
        }
    }

    private static func parsedUUID(
        _ value: String?,
        parameter: String
    ) -> Result<UUID?, CmuxRunURLParseError> {
        guard let value else { return .success(nil) }
        guard let id = UUID(uuidString: value) else {
            return .failure(.invalidIdentifier(parameter))
        }
        return .success(id)
    }

    private static func containsUnsafeCommandCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            if scalar.value == 0x09 || scalar.value == 0x0A {
                return false
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    static func containsUnsafeHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func displayParameterName(_ name: String) -> String {
        guard !name.isEmpty, !containsUnsafeHiddenCharacter(name) else { return "?" }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return "?" }
        let prefix = String(name.prefix(64))
        return prefix.count == name.count ? name : "\(prefix)..."
    }
}
