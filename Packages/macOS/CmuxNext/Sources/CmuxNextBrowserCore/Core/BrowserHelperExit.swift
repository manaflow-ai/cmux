/// One engine helper process's abnormal end, once per process: the end its `cef.helper_exit` sample counts
/// (``BrowserCrashLog/helperExited(_:)``). The crash reporter sends it as one Sentry event, rate-limited per
/// ``processType``. Holds no page content (no URL, title or tab), only names Chromium gives its helpers, the
/// reason, the code and the message pump's numbers.
public nonisolated struct BrowserHelperExit: Hashable, Sendable {
    /// The helper's kind: `renderer`, `extension`, `gpu`, `utility` or `other` (a few fixed names, the
    /// rate limit's key).
    public var processType: String
    /// The helper's Chromium `--type=` value (`renderer`, `gpu-process`, `utility`, `crashpad-handler`).
    public var chromiumType: String
    /// Chromium's utility sub type (`network.mojom.NetworkService`), if any.
    public var subType: String?
    /// The helper's pid, which the macOS crash report (`.ips`) and the minidump of the same process carry;
    /// nil when no exit of the process was seen (a renderer that never launched, or one in host mode, where
    /// the renderers are the Chromium host's children).
    public var pid: Int32?
    public var reason: BrowserProcessExit.Reason
    /// The raw `waitpid` status or Chromium's exit code, when known.
    public var code: Int?
    /// The message pump when the helper ended: numbers and fixed states only (`mode`, `work_runs`,
    /// `long_work_runs`, `pass_p99_ms`).
    public var pump: [String: String]

    public init(processType: String, chromiumType: String, subType: String? = nil, pid: Int32? = nil,
                reason: BrowserProcessExit.Reason, code: Int? = nil, pump: [String: String] = [:]) {
        self.processType = processType
        self.chromiumType = chromiumType
        self.subType = subType
        self.pid = pid
        self.reason = reason
        self.code = code
        self.pump = pump
    }

    /// The code as `SIGSEGV` or `exit 3` (``BrowserProcessExit/codeDescription``).
    public var codeDescription: String? { BrowserProcessExit(reason: reason, code: code).codeDescription }
}
