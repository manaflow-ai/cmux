enum MobileConnectionRecoveryBannerPresentation: Equatable {
    case hidden
    case reconnecting
    case lost
    case reauth(String)
}
