import Foundation

/// The title AppKit uses for the Dock, Window menu, Mission Control and Cmd-` lists.
/// Keep the space first so two windows showing the same workspace name remain distinguishable.
public struct WindowListTitle: Equatable, Sendable {
    public let value: String

    public init(spaceName: String?, workspaceName: String?, incognito: Bool,
                fallbackName: String, incognitoName: String) {
        let space = incognito ? incognitoName : Self.nonEmpty(spaceName) ?? fallbackName
        let workspace = Self.nonEmpty(workspaceName)
        value = [space, workspace].compactMap { $0 }.joined(separator: " — ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
