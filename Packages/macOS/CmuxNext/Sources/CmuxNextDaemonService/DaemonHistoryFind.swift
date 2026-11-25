public import CmuxNextDaemon
public import CmuxNextTerminalFind
import Foundation

/// A terminal's whole-history find, served by its daemon (`terminal-find`): Cmd-F in the terminal
/// searches every retained row, not the screen Ghostty mirrors. The daemon matches and pages; this
/// sends the request and maps the answer.
@MainActor
public final class DaemonHistoryFind: TerminalFindHistory {
    private weak var daemon: DaemonService?
    private let surface: SurfaceID

    public init(daemon: DaemonService, surface: SurfaceID) {
        self.daemon = daemon
        self.surface = surface
    }

    public func page(_ request: TerminalFindPageRequest) async throws -> TerminalFindPage {
        guard let connection = daemon?.connection else { throw DaemonError.notConnected }
        let response = try await connection.request(
            TerminalFindRequest(surface: surface, query: request.query, caseSensitive: request.options.caseSensitive,
                                wholeWord: request.options.wholeWord, regex: request.options.regex,
                                before: request.before, epoch: request.epoch),
            timeout: .seconds(10))
        let matches = response.matches.map { found in
            TerminalFindMatch(startMarker: found.start.marker, startColumn: Int(found.start.column), endMarker: found.end.marker,
                              endColumn: Int(found.end.column), rowsFromBottom: Int(clamping: found.rowsFromBottom), text: found.text)
        }
        return TerminalFindPage(matches: matches, nextBefore: response.nextBefore, epoch: response.epoch ?? 0,
                                restarted: response.restarted ?? false, invalidPattern: response.invalidPattern,
                                columns: Int(response.cols ?? 80))
    }
}
