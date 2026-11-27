public import CmuxNextCompat
public import Foundation

extension BrowserEngineFailure {
    /// CEF's `OnRenderProcessTerminated` for a page: the termination and code
    /// named as the sad tab names them (``BrowserProcessExit``).
    /// - Parameters:
    ///   - status: `cef_termination_status_t` (``BrowserProcessExit/cef(status:code:)``).
    ///   - code: The `waitpid` status CEF reports.
    ///   - text: CEF's error string.
    ///   - url: The page's address; only its scheme and host are kept.
    ///   - versions: The engine versions.
    /// - Returns: The failure.
    public nonisolated static func rendererTerminated(status: Int, code: Int, text: String, url: URL?,
                                          versions: BrowserEngineVersions = BrowserEngineVersions()) -> BrowserEngineFailure {
        let exit = BrowserProcessExit.cef(status: status, code: code)
        return BrowserEngineFailure(kind: .rendererTerminated, code: code, codeName: exit.codeDescription,
                                    termination: exit.reason.rawValue, site: site(of: url), processKind: "renderer",
                                    reason: text, versions: versions)
    }
}
