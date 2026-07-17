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
}

