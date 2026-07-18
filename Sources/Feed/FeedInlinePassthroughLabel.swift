import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

