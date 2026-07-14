import Foundation

struct UsageTipPresentation: Identifiable, Equatable {
    let tip: UsageTip
    let shortcutLabel: String?
    let windowID: UUID

    var id: UsageTipID { tip.id }
}
