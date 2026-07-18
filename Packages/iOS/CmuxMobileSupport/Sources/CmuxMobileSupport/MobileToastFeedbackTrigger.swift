import Foundation
import SwiftUI

struct MobileToastFeedbackTrigger: Equatable {
    let id: UUID
    let feedback: MobileToastFeedback

    var sensoryFeedback: SensoryFeedback {
        switch feedback {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}
