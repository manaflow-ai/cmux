struct MobileToastPresentation {
    let toast: MobileToast
    let onDismiss: (@MainActor @Sendable (MobileToastDismissReason) -> Void)?
}
