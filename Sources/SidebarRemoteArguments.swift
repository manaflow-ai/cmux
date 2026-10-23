import Foundation

/// The window or workspace a sidebar socket command targets. With neither,
/// the command acts on the active window.
struct SidebarRemoteTarget: Equatable, Sendable {
    var windowId: UUID? = nil
    var workspaceId: UUID? = nil

    var isActiveTarget: Bool {
        windowId == nil && workspaceId == nil
    }
}

/// The words, target and `--no-focus` flag of a sidebar socket command, with
/// its target options already read and checked.
struct SidebarRemoteArguments: Equatable, Sendable {
    var positional: [String] = []
    var target = SidebarRemoteTarget()
    var noFocus = false
}

struct SidebarRemoteArgumentsError: Error, Equatable, Sendable {
    let message: String
}

/// Reply text for the options every sidebar command reads; each sidebar
/// names itself in these messages.
struct SidebarRemoteArgumentsMessages {
    let optionRequiresID: (_ option: String) -> String
    let unknownOption: (_ option: String) -> String
    let invalidTargetID: (_ name: String, _ value: String) -> String
}

extension SidebarRemoteArguments {
    /// Reads `--workspace`, `--tab` and `--window` (spaced or with `=`), and
    /// `--no-focus` when the sidebar accepts it. Any other `--` option fails.
    static func parse(
        tokens: [String],
        acceptsNoFocus: Bool,
        messages: SidebarRemoteArgumentsMessages
    ) -> Result<SidebarRemoteArguments, SidebarRemoteArgumentsError> {
        var arguments = SidebarRemoteArguments()
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if acceptsNoFocus && token == "--no-focus" {
                arguments.noFocus = true
                index += 1
                continue
            }
            if token == "--workspace" || token == "--tab" || token == "--window" {
                guard index + 1 < tokens.count else {
                    return .failure(.init(message: messages.optionRequiresID(token)))
                }
                let name = String(token.dropFirst(2))
                let value = tokens[index + 1]
                guard arguments.setTarget(name: name, value: value) else {
                    return .failure(.init(message: messages.invalidTargetID(name, value)))
                }
                index += 2
                continue
            }
            if let name = ["workspace", "tab", "window"].first(where: { token.hasPrefix("--\($0)=") }) {
                let value = String(token.dropFirst("--\(name)=".count))
                guard arguments.setTarget(name: name, value: value) else {
                    return .failure(.init(message: messages.invalidTargetID(name, value)))
                }
                index += 1
                continue
            }
            if token.hasPrefix("--") {
                return .failure(.init(message: messages.unknownOption(token)))
            }
            arguments.positional.append(token)
            index += 1
        }
        return .success(arguments)
    }

    /// Sets the window (`window`) or workspace (`workspace`/`tab`) target;
    /// false when `value` is not a UUID.
    private mutating func setTarget(name: String, value: String) -> Bool {
        guard let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        if name == "window" {
            target.windowId = uuid
        } else {
            target.workspaceId = uuid
        }
        return true
    }
}
