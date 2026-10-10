import CoreGraphics
import Foundation

/// Where the conversation details header's parts sit for a content offset.
public struct ConversationDetailsHeaderLayout: Equatable, Sendable {
    /// The avatar (or group cluster) square.
    public var avatar: CGRect
    /// Top of the title's 33.67 pt line box; the title scales about its top center.
    public var titleTop: CGFloat
    public var titleScale: CGFloat
    /// Call, video and mail circles (48 pt, 20 pt apart).
    public var quickActions: CGRect
    public var quickActionsAlpha: CGFloat
    /// Info / Backgrounds; it scrolls with the content, then pins under the
    /// collapsed header.
    public var tabBar: CGRect
    /// Where the page content starts (the header's height) at rest offset.
    public var height: CGFloat
}

/// Messages' details header (CommunicationDetails `DetailsViewController+
/// HeaderCollapsing`), read from MobileSMS on iOS 26.5 (iPhone 17 Pro Max)
/// by setting the details scroll view's offset and dumping the header:
///
/// - at rest an 80 pt avatar at the safe top, the 28 pt bold title 84 pt
///   below it, 48 pt quick actions 49.67 pt under the title's top, and the
///   tabs (when shown) 20 pt under those;
/// - scrolling collapses it over 97.23 pt: the avatar shrinks to 60 pt, the
///   title rises 23 pt and scales to 0.63, the quick actions tuck up under
///   the title and fade out by 60 % of the way; the tabs scroll with the
///   content and then pin;
/// - pulling down stretches the same parts by `offset / (|offset| + 97.23)`
///   of their collapse range (an 80 pt avatar is 85.83 pt at -40).
public enum ConversationDetailsHeaderGeometry {
    public static let avatarSize: CGFloat = 80
    public static let collapsedAvatarSize: CGFloat = 60
    /// From the avatar's top to the title's line box.
    public static let titleTopFromAvatar: CGFloat = 84
    public static let titleHeight: CGFloat = 101.0 / 3
    public static let titleCollapseRise: CGFloat = 23
    public static let collapsedTitleScale: CGFloat = 0.63
    public static let quickActionSize: CGFloat = 48
    public static let quickActionSpacing: CGFloat = 20
    public static let quickActionCount = 3
    /// Quick actions' top below the title's top, at rest and collapsed.
    public static let quickActionsFromTitle: CGFloat = 149.0 / 3
    public static let collapsedQuickActionsFromTitle: CGFloat = 5.0 / 3
    /// Share of the collapse by which the quick actions are gone.
    public static let quickActionsFadeEnd: CGFloat = 0.6
    public static let tabBarHeight: CGFloat = 34
    /// Space above the tabs and below the quick actions (or the tabs).
    public static let sectionGap: CGFloat = 20
    /// A group's title, actions and tabs sit lower under its cluster.
    public static let groupDrop: CGFloat = 13.0 / 3
    /// The content offset over which the header collapses.
    public static let collapseDistance: CGFloat = 97.23

    /// Collapse progress: the offset's share of `collapseDistance`, held at 1;
    /// pulled down it tends to -1 like a rubber band.
    public static func progress(offset: CGFloat) -> CGFloat {
        if offset >= 0 { return min(1, offset / collapseDistance) }
        return offset / (-offset + collapseDistance)
    }

    public static func layout(width: CGFloat, safeTop: CGFloat, offset: CGFloat, showsTabs: Bool, isGroup: Bool) -> ConversationDetailsHeaderLayout {
        let p = progress(offset: offset)
        let size = avatarSize - (avatarSize - collapsedAvatarSize) * p
        let drop = isGroup ? groupDrop : 0
        let titleTop = safeTop + titleTopFromAvatar + drop - titleCollapseRise * p
        let actionsFromTitle = quickActionsFromTitle - (quickActionsFromTitle - collapsedQuickActionsFromTitle) * p
        let actionsWidth = CGFloat(quickActionCount) * quickActionSize + CGFloat(quickActionCount - 1) * quickActionSpacing
        let restActionsBottom = safeTop + titleTopFromAvatar + drop + quickActionsFromTitle + quickActionSize
        let restTabTop = restActionsBottom + sectionGap
        let tabTop = restTabTop - collapseDistance * p
        let restHeight = showsTabs ? restTabTop + tabBarHeight + sectionGap : restActionsBottom + sectionGap
        return ConversationDetailsHeaderLayout(
            avatar: CGRect(x: (width - size) / 2, y: safeTop, width: size, height: size),
            titleTop: titleTop,
            titleScale: 1 - (1 - collapsedTitleScale) * p,
            quickActions: CGRect(x: (width - actionsWidth) / 2, y: titleTop + actionsFromTitle, width: actionsWidth, height: quickActionSize),
            quickActionsAlpha: max(0, min(1, 1 - p / quickActionsFadeEnd)),
            tabBar: CGRect(x: 0, y: tabTop, width: width, height: tabBarHeight),
            height: restHeight - collapseDistance * max(0, p)
        )
    }

    /// The zoom transition's alignment rect in the details view
    /// (`UIZoomTransitionOptions.alignmentRectProvider` in Messages): a 208 pt
    /// square around the avatar, so the header's 60 pt avatar grows into it.
    public static let zoomAlignmentSide: CGFloat = 208

    public static func zoomAlignmentRect(width: CGFloat, safeTop: CGFloat) -> CGRect {
        let center = CGPoint(x: width / 2, y: safeTop + avatarSize / 2)
        return CGRect(x: center.x - zoomAlignmentSide / 2, y: center.y - zoomAlignmentSide / 2, width: zoomAlignmentSide, height: zoomAlignmentSide)
    }
}

/// The details' Info / Backgrounds selection capsule (CommunicationDetails
/// DetailsTabBarView), measured in a 60 fps recording of real Messages.
public enum ConversationDetailsTabGeometry {
    /// The capsule slides between tabs on this spring (damping 0.85,
    /// response 0.435 s), widening or narrowing to the new title.
    public static let selectionSpring = spring(dampingRatio: 0.85, response: 0.435)
    /// A touch lifts the capsule (it grows 8 pt a side, 5 pt top and
    /// bottom) on a quick critically damped spring.
    public static let liftSpring = spring(dampingRatio: 1, response: 0.15)
    public static let liftOutset = CGSize(width: 8, height: 5)

    public static func capsule(_ rest: CGRect, lift: CGFloat) -> CGRect {
        rest.insetBy(dx: -liftOutset.width * lift, dy: -liftOutset.height * lift)
    }

    static func spring(dampingRatio: CGFloat, response: CGFloat) -> SendMenuGeometry.Spring {
        let stiffness = pow(2 * .pi / response, 2)
        return SendMenuGeometry.Spring(mass: 1, stiffness: stiffness, damping: 2 * dampingRatio * stiffness.squareRoot(), settlingDuration: Double(response) * 2)
    }
}
