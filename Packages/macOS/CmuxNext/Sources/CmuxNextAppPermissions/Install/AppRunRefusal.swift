/// The channel that asks to run an app.
public nonisolated enum AppRunOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case user
    case cli
    case mcp
    case automation
}

/// Why a run is refused; `code` is the error the caller receives.
public nonisolated enum AppRunRefusal: Error, Sendable, Hashable {
    case notInstalled
    case disabled
    case hidden

    public var code: String {
        switch self {
        case .notInstalled: "app.not_installed"
        case .disabled: "app.disabled"
        case .hidden: "app.hidden"
        }
    }
}
