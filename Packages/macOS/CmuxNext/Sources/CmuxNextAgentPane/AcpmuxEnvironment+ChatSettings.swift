import Foundation

extension AcpmuxEnvironment {
    /// Applies the app's device-chat privacy projection over a checked connection that proves the
    /// in-memory person key. A same-UID agent cannot call the daemon's person-only method.
    public nonisolated func applyChatSettings(
        enabled: Bool,
        discovery: Bool,
        roots: [String],
        managedRoots: [String],
        deadline: Duration = .seconds(5)
    ) async -> Bool {
        let result = await AcpmuxPersonLine.request(
            self,
            method: "_acpmux/chat_settings",
            params: [
                "enabled": enabled,
                "discovery": discovery,
                "roots": roots,
                "managedRoots": managedRoots,
            ],
            deadline: deadline
        )
        return result?.value["applied"] as? Bool == true
    }
}
