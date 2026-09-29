public import CmuxNextSettings

/// App-owned state changes the CLI requests (architecture.md 1: windows,
/// which workspace each shows, focus, and tab selection belong to the app).
/// Reads never come here: they answer from the published `ControlSnapshot`.
///
/// `perform` runs on the main actor through the router's bounded
/// `MainActorWorkQueue` and must be short and synchronous. `browser` is
/// async (page scripts); the App hops to the main actor itself and the
/// request deadline bounds it.
public protocol CompatFrontend: Sendable {
    @MainActor func perform(_ intent: CompatFrontendIntent) throws -> JSONValue
    func browser(tabID: String, url: String?, operation: CompatBrowserOperation) async throws -> JSONValue
}

/// Frontend for tests and headless runs: no windows, every intent refused.
public struct HeadlessCompatFrontend: CompatFrontend {
    public init() {}

    @MainActor public func perform(_ intent: CompatFrontendIntent) throws -> JSONValue {
        throw CompatErrors.unsupported(ControlStrings.format("control.error.noAppWindow", "no app window is available for %@", "\(intent)"))
    }

    public func browser(tabID: String, url: String?, operation: CompatBrowserOperation) async throws -> JSONValue {
        throw CompatErrors.unsupported(ControlStrings.text("control.error.noBrowserEngine", "no browser engine is available"))
    }
}
