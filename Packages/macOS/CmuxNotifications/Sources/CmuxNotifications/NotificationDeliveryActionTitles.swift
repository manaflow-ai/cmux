/// Localized action titles used when installing OS notification categories.
/// The app target creates this value so localization continues to resolve from
/// the app bundle while the package owns category composition.
public struct NotificationDeliveryActionTitles: Sendable, Equatable {
    /// Title for opening a terminal notification.
    public let show: String

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

    /// Title for opening a feed question in the app.
    public let feedQuestionReply: String

    /// Creates the localized titles used by delivery-category actions.
    public init(
        show: String,
        feedPermissionAllowOnce: String,
        feedPermissionAlways: String,
        feedPermissionAll: String,
        feedPermissionDeny: String,
        feedExitPlanUltraplan: String,
        feedExitPlanManual: String,
        feedExitPlanAutoAccept: String,
        feedQuestionReply: String
    ) {
        self.show = show
        self.feedPermissionAllowOnce = feedPermissionAllowOnce
        self.feedPermissionAlways = feedPermissionAlways
        self.feedPermissionAll = feedPermissionAll
        self.feedPermissionDeny = feedPermissionDeny
        self.feedExitPlanUltraplan = feedExitPlanUltraplan
        self.feedExitPlanManual = feedExitPlanManual
        self.feedExitPlanAutoAccept = feedExitPlanAutoAccept
        self.feedQuestionReply = feedQuestionReply
    }
}
