import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

struct FeedStopDraft: Equatable {
    var reply = ""

    var isPristine: Bool {
        reply.isEmpty
    }

    mutating func finishSend(submittedReply: String, succeeded: Bool) {
        guard succeeded,
              reply.trimmingCharacters(in: .whitespacesAndNewlines) == submittedReply
        else { return }
        reply = ""
    }
}
