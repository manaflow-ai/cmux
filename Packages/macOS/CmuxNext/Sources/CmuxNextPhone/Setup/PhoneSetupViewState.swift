/// Everything the setup screen shows, as a value: built from the
/// coordinator's state, so the screen's content is tested without AppKit.
public struct PhoneSetupViewState: Sendable, Hashable {
    /// One row of the step list.
    public struct Row: Sendable, Hashable {
        public var title: String
        public var done: Bool
        public var current: Bool
    }

    /// A button: its title and what it does.
    public struct Button: Sendable, Hashable {
        public var title: String
        public var action: PhoneSetupAction
    }

    public var title: String
    public var body: String
    public var rows: [Row]
    public var primary: Button?
    public var secondary: Button?
    /// 0...1 for a determinate bar, nil for an indeterminate one; only shown when ``progressText`` is set.
    public var progress: Double?
    public var progressText: String?
    /// The last failure, in plain words.
    public var failure: String?
    /// The failure's raw text, for the tooltip.
    public var failureDetail: String?

    /// The screen for the coordinator's state.
    public init(status: PhoneSetupStatus?, activity: PhoneSetupActivity?, failure: PhoneErrorText?) {
        let step = status?.step ?? .installXcode
        rows = PhoneSetupStep.checklist.map { row in
            Row(title: Self.title(of: row), done: status != nil && row.isBefore(step), current: status != nil && row == step)
        }
        self.failure = failure?.message
        failureDetail = failure?.detail
        progress = nil
        progressText = nil
        secondary = nil
        guard let status else {
            title = PhoneStrings.setupChecking
            body = ""
            primary = nil
            progressText = PhoneStrings.setupChecking
            return
        }
        switch status.step {
        case .installXcode:
            title = PhoneStrings.setupInstallXcodeTitle
            body = PhoneStrings.setupInstallXcodeBody + (status.hasOnlyCommandLineTools ? "\n\n" + PhoneStrings.setupCommandLineToolsNote : "")
            primary = Button(title: PhoneStrings.setupOpenAppStore, action: .openAppStore)
            secondary = Button(title: PhoneStrings.setupXcodeWebsite, action: .openXcodeWebsite)
        case .finishXcode:
            title = PhoneStrings.setupFinishXcodeTitle
            body = PhoneStrings.setupFinishXcodeBody
            primary = Button(title: PhoneStrings.setupOpenXcode, action: .openXcode(status.xcodeApp ?? "/Applications/Xcode.app"))
        case .downloadIOS:
            title = PhoneStrings.setupDownloadTitle
            body = PhoneStrings.setupDownloadBody
            primary = Button(title: PhoneStrings.setupDownload, action: .downloadIOS)
        case .createIPhone, .ready:
            title = PhoneStrings.setupCreateTitle
            body = PhoneStrings.setupCreateBody
            let model = status.runtime?.suggestedIPhone?.name
            primary = Button(title: model.map(PhoneStrings.setupCreate) ?? PhoneStrings.setupCreateTitle, action: .createIPhone)
        }
        switch activity {
        case .downloading(let now)?:
            progress = now.fraction
            progressText = now.fraction.map { PhoneStrings.setupDownloading(percent: Int(($0 * 100).rounded(.down))) + (now.amount.map { " (\($0))" } ?? "") }
                ?? PhoneStrings.setupDownloadStarting
            primary = Button(title: PhoneStrings.setupCancel, action: .cancelDownload)
            secondary = nil
        case .creating?:
            progressText = PhoneStrings.setupCreating
            primary = nil
        case .checking?:
            progressText = PhoneStrings.setupChecking
        case nil:
            break
        }
    }

    static func title(of step: PhoneSetupStep) -> String {
        switch step {
        case .installXcode: PhoneStrings.stepInstallXcode
        case .finishXcode: PhoneStrings.stepFinishXcode
        case .downloadIOS: PhoneStrings.stepDownloadIOS
        case .createIPhone, .ready: PhoneStrings.stepCreateIPhone
        }
    }
}
