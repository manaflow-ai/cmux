public import CmuxNextCompat

extension BrowserEngineFailure {
    /// A Chromium helper process with no tab of its own ended abnormally
    /// (`CEFChildProcessMonitor`): an extension renderer, the GPU process or a
    /// utility process. Such an end shows no sad tab, because Chromium restarts the helper.
    /// - Parameters:
    ///   - processKind: The helper kind: `extension`, `gpu-process`, `utility`.
    ///   - subType: Chromium's `--utility-sub-type`, `network.mojom.NetworkService`; nil for others.
    ///   - reason: Why it ended (``BrowserProcessExit/Reason``).
    ///   - status: The raw `waitpid` status.
    ///   - versions: The engine versions.
    /// - Returns: The failure.
    public nonisolated static func helperEnded(processKind: String, subType: String?, reason: BrowserProcessExit.Reason,
                                               status: Int,
                                               versions: BrowserEngineVersions = BrowserEngineVersions()) -> BrowserEngineFailure {
        let exit = BrowserProcessExit(reason: reason, code: status == 0 ? nil : status, engine: .cef)
        return BrowserEngineFailure(kind: .helperEnded, code: status, codeName: exit.codeDescription,
                                    termination: reason.rawValue, processKind: processKind, reason: subType,
                                    versions: versions)
    }
}
