/// Localized action titles used when installing OS notification categories.
/// The app target creates this value so localization continues to resolve from
/// the app bundle while the package owns category composition.
public struct NotificationDeliveryActionTitles: Sendable, Equatable {
    /// Title for opening a terminal notification.
    public let show: String

    /// Title for starting a terminal notification reply.
    public let reply: String

    /// Title for sending a terminal notification reply.
    public let replySend: String

    /// Placeholder for terminal notification reply text.
    public let replyPlaceholder: String

    /// Title for allowing a permission request once.
    public let feedPermissionAllowOnce: String

    /// Title for allowing a permission request persistently.
    public let feedPermissionAlways: String

    /// Title for allowing every matching permission request.
    public let feedPermissionAll: String

    /// Title for denying a permission request.
    public let feedPermissionDeny: String

    /// Title for accepting an exit plan with Ultraplan.
    public let feedExitPlanUltraplan: String

    /// Title for accepting an exit plan manually.
    public let feedExitPlanManual: String

    /// Title for accepting an exit plan automatically.
    public let feedExitPlanAutoAccept: String

    /// Title for revising an exit plan with free-text feedback.
    public let feedExitPlanRevise: String

    /// Title for opening a feed question in the app.
    public let feedQuestionReply: String

    /// Title for answering a feed question with free text.
    public let feedQuestionOther: String

    /// Creates the localized titles used by delivery-category actions.
    public init(
        show: String,
        reply: String,
        replySend: String,
        replyPlaceholder: String,
        feedPermissionAllowOnce: String,
        feedPermissionAlways: String,
        feedPermissionAll: String,
        feedPermissionDeny: String,
        feedExitPlanUltraplan: String,
        feedExitPlanManual: String,
        feedExitPlanAutoAccept: String,
        feedExitPlanRevise: String,
        feedQuestionReply: String,
        feedQuestionOther: String
    ) {
        self.show = show
        self.reply = reply
        self.replySend = replySend
        self.replyPlaceholder = replyPlaceholder
        self.feedPermissionAllowOnce = feedPermissionAllowOnce
        self.feedPermissionAlways = feedPermissionAlways
        self.feedPermissionAll = feedPermissionAll
        self.feedPermissionDeny = feedPermissionDeny
        self.feedExitPlanUltraplan = feedExitPlanUltraplan
        self.feedExitPlanManual = feedExitPlanManual
        self.feedExitPlanAutoAccept = feedExitPlanAutoAccept
        self.feedExitPlanRevise = feedExitPlanRevise
        self.feedQuestionReply = feedQuestionReply
        self.feedQuestionOther = feedQuestionOther
    }
}
