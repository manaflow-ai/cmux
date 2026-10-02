/// How urgently a hidden pane's web content is being released.
public enum BrowserHiddenWebViewDiscardUrgency: Sendable {
    /// Hidden time or the hidden memory budget. Anything a restore cannot
    /// bring back keeps the pane.
    case routine
    /// The system is under memory pressure. State a restore cannot bring back,
    /// such as typed input the form restore skips or a WebContent process that
    /// died mid-load, no longer keeps the pane. Live activity still does.
    case systemMemoryPressure

    public init(reason: String) {
        self = reason == BrowserHiddenWebViewDiscardManager.systemMemoryPressureReason
            ? .systemMemoryPressure
            : .routine
    }
}

extension BrowserHiddenWebViewDiscardManager {
    public struct BlockerSnapshot {
        public let isClosing: Bool
        public let isVisibleInUI: Bool
        public let shouldRenderWebView: Bool
        public let hasPendingRemoteNavigation: Bool
        public let hasCurrentURL: Bool
        public let isLoading: Bool
        public let webViewIsLoading: Bool
        public let hasActiveMainFrameProvisionalNavigation: Bool
        public let hasRecoverableWebContentTermination: Bool
        public let isDownloading: Bool
        public let activeDownloadCount: Int
        public let preferredDeveloperToolsVisible: Bool
        public let isDeveloperToolsVisible: Bool
        public let isElementFullscreenActive: Bool
        public let isReactGrabActive: Bool
        public var isDesignModeActive = false
        public let isVisualAutomationCaptureActive: Bool
        public let isMobileBrowserStreamActive: Bool
        public let hasPopups: Bool
        public let isCapturingMedia: Bool
        public let isPlayingMedia: Bool
        public var isPictureInPictureActive = false
        /// The page holds typed input the form restore does not replay, such
        /// as a password or a rich-text edit.
        public var hasUnrestorableFormInput = false

        public init(
            isClosing: Bool,
            isVisibleInUI: Bool,
            shouldRenderWebView: Bool,
            hasPendingRemoteNavigation: Bool,
            hasCurrentURL: Bool,
            isLoading: Bool,
            webViewIsLoading: Bool,
            hasActiveMainFrameProvisionalNavigation: Bool,
            hasRecoverableWebContentTermination: Bool = false,
            isDownloading: Bool,
            activeDownloadCount: Int,
            preferredDeveloperToolsVisible: Bool,
            isDeveloperToolsVisible: Bool,
            isElementFullscreenActive: Bool,
            isReactGrabActive: Bool,
            isDesignModeActive: Bool = false,
            isVisualAutomationCaptureActive: Bool,
            isMobileBrowserStreamActive: Bool = false,
            hasPopups: Bool,
            isCapturingMedia: Bool,
            isPlayingMedia: Bool,
            isPictureInPictureActive: Bool = false,
            hasUnrestorableFormInput: Bool = false
        ) {
            self.isClosing = isClosing
            self.isVisibleInUI = isVisibleInUI
            self.shouldRenderWebView = shouldRenderWebView
            self.hasPendingRemoteNavigation = hasPendingRemoteNavigation
            self.hasCurrentURL = hasCurrentURL
            self.isLoading = isLoading
            self.webViewIsLoading = webViewIsLoading
            self.hasActiveMainFrameProvisionalNavigation = hasActiveMainFrameProvisionalNavigation
            self.hasRecoverableWebContentTermination = hasRecoverableWebContentTermination
            self.isDownloading = isDownloading
            self.activeDownloadCount = activeDownloadCount
            self.preferredDeveloperToolsVisible = preferredDeveloperToolsVisible
            self.isDeveloperToolsVisible = isDeveloperToolsVisible
            self.isElementFullscreenActive = isElementFullscreenActive
            self.isReactGrabActive = isReactGrabActive
            self.isDesignModeActive = isDesignModeActive
            self.isVisualAutomationCaptureActive = isVisualAutomationCaptureActive
            self.isMobileBrowserStreamActive = isMobileBrowserStreamActive
            self.hasPopups = hasPopups
            self.isCapturingMedia = isCapturingMedia
            self.isPlayingMedia = isPlayingMedia
            self.isPictureInPictureActive = isPictureInPictureActive
            self.hasUnrestorableFormInput = hasUnrestorableFormInput
        }
    }
}
