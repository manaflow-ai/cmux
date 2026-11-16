import CmuxNextCompat
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

/// Shared observation loop for native window-list titles. AppKit owners provide the
/// app-specific values and decide whether the visible titlebar should also change.
/// Publishes once synchronously, then only on observed changes. The window owner
/// cancels the returned task when replacing the binding or tearing the window down.
public enum WindowListTitleObservation {
    public typealias Value = (spaceName: String?, workspaceName: String?, incognito: Bool, showsWorkspaceChrome: Bool)

    @MainActor
    public static func start(
        values: @escaping @MainActor @Sendable () -> Value,
        fallbackName: String,
        incognitoName: String,
        apply: @escaping @MainActor @Sendable (_ title: String, _ workspaceName: String?, _ showsWorkspaceChrome: Bool) -> Void
    ) -> Task<Void, Never> {
        let stream = ObservationStream<Value>.current(values)
        let publish: @MainActor @Sendable (Value) -> Void = { value in
            let title = WindowListTitle(
                spaceName: value.spaceName,
                workspaceName: value.workspaceName,
                incognito: value.incognito,
                fallbackName: fallbackName,
                incognitoName: incognitoName
            ).value
            apply(title, value.workspaceName, value.showsWorkspaceChrome)
        }
        publish(stream.value)
        return Task {
            for await value in stream.later {
                guard !Task.isCancelled else { return }
                publish(value)
            }
        }
    }
}
