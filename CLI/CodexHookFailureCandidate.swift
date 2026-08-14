struct CodexHookFailureCandidate {
    let message: String
    let codexErrorInfo: String?
    let additionalDetails: String?
    let isStreamError: Bool
    /// True when the candidate came from a terminal assistant banner rather
    /// than a structured Codex error event. Structured errors retain their
    /// historical subtitles; provider banners use the shared abnormal-stop
    /// classifier so their known class is visible to the user.
    let isAbnormalStopBanner: Bool

    init(
        message: String,
        codexErrorInfo: String?,
        additionalDetails: String?,
        isStreamError: Bool,
        isAbnormalStopBanner: Bool = false
    ) {
        self.message = message
        self.codexErrorInfo = codexErrorInfo
        self.additionalDetails = additionalDetails
        self.isStreamError = isStreamError
        self.isAbnormalStopBanner = isAbnormalStopBanner
    }
}
