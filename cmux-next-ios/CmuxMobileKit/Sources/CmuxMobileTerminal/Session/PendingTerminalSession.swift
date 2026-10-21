import CmuxMobileArtifacts
import Foundation

/// A terminal tab whose session on the Mac does not exist yet (the link or
/// the workspace tree is still coming). It shows nothing but the connecting
/// placeholder and drops input; the tab's host is replaced by the live
/// session once there is one.
@MainActor
public final class PendingTerminalSession: TerminalSession {
    public let programName: String
    public let macName: String?
    public var isAlternateScreen: Bool { false }
    public var connectionState: TerminalConnectionState { .connecting(mac: macName) }

    /// `programName`: the tab's title; a folder title (the daemon's shell
    /// tabs) or none reads "terminal", as the live session does.
    public init(macName: String?, programName: String = "terminal") {
        self.macName = macName
        let isFolder = programName.hasPrefix("/") || programName.hasPrefix("~") || programName.isEmpty
        self.programName = isFolder ? "terminal" : programName
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        handler(.connection(connectionState))
    }

    /// Nothing to send to: there is no terminal yet.
    public func send(_ bytes: Data) {}
    public func resize(columns: Int, rows: Int) {}
    public func stop() {}
}

/// Picks a terminal tab's session and artifact source. A live session always
/// wins; without one the tab is honest about connecting. The scripted mock is
/// only compiled into DEBUG (and Demo) builds and only used when the developer
/// turned mock data on.
@MainActor
public enum TerminalSessionChoice {
    /// Whether this build carries mock content at all (false in Production).
    public nonisolated static var mockCompiledIn: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// `live`: the Mac's session for the tab, when it exists. `mockDataEnabled`:
    /// Settings → Developer → Mock (or a mock launch); ignored outside DEBUG.
    public static func session(
        live: (any TerminalSession)?,
        mockDataEnabled: Bool,
        macName: String?,
        programName: String
    ) -> any TerminalSession {
        if let live { return live }
        #if DEBUG
        if mockDataEnabled {
            // A Codex-like inline TUI streaming history (reproduction harness).
            if ProcessInfo.processInfo.arguments.contains("-cmux-mobile-term-fake-codex") { return FakeCodexSession() }
            if ProcessInfo.processInfo.arguments.contains("-cmux-mobile-term-fake-codex-idle") { return FakeCodexSession(idleRedraw: true) }
            return MockTerminalSession()
        }
        #endif
        return PendingTerminalSession(macName: macName, programName: programName)
    }

    /// Files and Links for a tab with no live source: the mock files only in
    /// mock mode, else an empty source that says the Mac is not connected.
    public static func fallbackArtifactSource(mockDataEnabled: Bool) -> any ArtifactSource {
        #if DEBUG
        if mockDataEnabled { return MockArtifactSource() }
        #endif
        return UnavailableArtifactSource()
    }
}
