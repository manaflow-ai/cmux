import Foundation
import SwiftUI

/// Direction from which a new split animates in
enum SplitAnimationOrigin {
    case fromFirst   // New pane slides in from start (left/top)
    case fromSecond  // New pane slides in from end (right/bottom)
}

/// State for a split node (branch in the split tree)
@Observable
final class MutableSplitState: Identifiable {
    let id: UUID
    var orientation: LayoutOrientation
    var first: MutableSplitNode
    var second: MutableSplitNode
    var dividerPosition: CGFloat  // 0.0 to 1.0

    /// Animation origin for entry animation (nil = no animation needed)
    var animationOrigin: SplitAnimationOrigin?

    init(
        id: UUID = UUID(),
        orientation: LayoutOrientation,
        first: MutableSplitNode,
        second: MutableSplitNode,
        dividerPosition: CGFloat = 0.5,
        animationOrigin: SplitAnimationOrigin? = nil
    ) {
        self.id = id
        self.orientation = orientation
        self.first = first
        self.second = second
        self.dividerPosition = dividerPosition
        self.animationOrigin = animationOrigin
    }
}

extension MutableSplitState: Equatable {
    static func == (lhs: MutableSplitState, rhs: MutableSplitState) -> Bool {
        lhs.id == rhs.id
    }
}
