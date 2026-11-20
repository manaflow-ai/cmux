import CoreGraphics
import Foundation

/// The conversation header's static layout, as iOS 26.5 and 27.0 Messages
/// draw it on iPhone (the two releases agree). Frames were read from
/// MobileSMS's view tree in the simulators (iPhone 17 Pro, 402 pt, and
/// iPhone 17 Pro Max, 440 pt) and the unread capsule from a dark-mode
/// iPhone 17 Pro Max screenshot of real Messages.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationHeaderGeometry {
    /// The back and trailing circles.
    public static let buttonSize: CGFloat = 44

    /// The back and trailing buttons sit on the navigation bar's layout
    /// margin: 16 pt on a 402 pt iPhone, 20 pt on a 440 pt one (the system
    /// minimum layout margin). Never tighter than 16.
    public static func sideMargin(layoutMargin: CGFloat) -> CGFloat {
        max(16, layoutMargin)
    }

    // MARK: Group cluster

    /// A group's first three other members on the header's 60 pt disc,
    /// largest first, measured on a real iPhone 17 Pro Max (iOS 26.4): the
    /// discs sit about 2 pt apart and never overlap.
    public static let groupClusterSlots: [CGRect] = [
        CGRect(x: 22.0 / 3, y: 22.0 / 3, width: 85.0 / 3, height: 85.0 / 3),
        CGRect(x: 34, y: 73.0 / 3, width: 65.0 / 3, height: 65.0 / 3),
        CGRect(x: 52.0 / 3, y: 112.0 / 3, width: 52.0 / 3, height: 52.0 / 3),
    ]

    /// The cluster's slots scaled onto `square` (the details page's 80 pt
    /// disc draws the same arrangement as the header's 60 pt one).
    public static func groupClusterSlots(in square: CGRect) -> [CGRect] {
        let k = square.width / 60
        return groupClusterSlots.map {
            CGRect(x: square.minX + $0.minX * k, y: square.minY + $0.minY * k, width: $0.width * k, height: $0.height * k)
        }
    }

    /// The cluster's discs are drawn bare; with the gaps no ring separates
    /// them.
    public static let groupClusterRingWidth: CGFloat = 0

    // MARK: Name

    /// The name capsule's bold type for the headline size Dynamic Type asks
    /// for (17 pt at Large), never smaller than at Large and held at 21 pt
    /// from XXL up.
    public static func namePointSize(scaled: CGFloat) -> CGFloat {
        min(max(scaled, 17), 21)
    }

    // MARK: Unread count in the back capsule

    /// The count is SF 12 medium (its "379" ink is 20.3 x 9 pt in Messages).
    public static let unreadFontSize: CGFloat = 12
    /// The light pill is 19 pt tall, 12.67 pt below the capsule's top.
    public static let unreadPillHeight: CGFloat = 19
    /// The pill starts 34.33 pt into the capsule ...
    public static let unreadPillLeading: CGFloat = 103.0 / 3
    /// ... and the capsule ends 17 pt after it.
    public static let unreadPillTrailing: CGFloat = 17
    /// Text inset on each side of the count's label inside the pill ("379",
    /// a 23 pt label, sits in a 34.67 pt pill).
    public static let unreadPillPadding: CGFloat = 35.0 / 6
    /// With a count the chevron moves 1.67 pt toward the leading edge.
    public static let unreadChevronShift: CGFloat = -5.0 / 3

    /// Pill width for a count whose label is `textWidth` wide; a single
    /// digit gets a circle.
    public static func unreadPillWidth(textWidth: CGFloat) -> CGFloat {
        max(unreadPillHeight, textWidth + 2 * unreadPillPadding)
    }

    /// The back capsule's width: a 44 pt circle without a count.
    public static func backWidth(unreadTextWidth: CGFloat?) -> CGFloat {
        guard let unreadTextWidth else { return buttonSize }
        return unreadPillLeading + unreadPillWidth(textWidth: unreadTextWidth) + unreadPillTrailing
    }

    /// The pill's frame inside the back capsule.
    public static func unreadPillFrame(textWidth: CGFloat) -> CGRect {
        CGRect(x: unreadPillLeading, y: (buttonSize - unreadPillHeight) / 2 + 1.0 / 6,
               width: unreadPillWidth(textWidth: textWidth), height: unreadPillHeight)
    }

    /// Messages centers the back chevron 1/3 pt below the circle's middle.
    public static let backChevronDrop: CGFloat = 1.0 / 3

    /// A layer shadow: black at `opacity`, blurred by `radius`, moved by
    /// `offset`, cast by a circle of `pathDiameter` at the layer origin.
    public struct AvatarShadow: Equatable, Sendable {
        public let opacity: Float
        public let radius: CGFloat
        public let offset: CGSize
        public let pathDiameter: CGFloat
    }

    /// ChatKit's CKAvatarButton shadow (iOS 27.0): black 30 %, radius 3,
    /// offset (5, 10), a 50 pt circle at the origin, so it hides behind the
    /// 60 pt photo but for a faint lower-right rim. UIKit's zoom morph carries
    /// the source's shadow; a source without one closes the details as a
    /// frosted glass card with a wide shadow, which Messages never shows.
    public static let avatarShadow = AvatarShadow(opacity: 0.3, radius: 3, offset: CGSize(width: 5, height: 10), pathDiameter: 50)
}

/// Messages' top scroll edge on iOS 26 (UIKit's pocket with a color): the
/// transcript washes toward the background, flat at the top, then an
/// S-shaped ramp that clears 46 pt below the header. The wash is 85.5%
/// opaque in light mode and 60% in dark mode (UIKit's pocket backdrop alpha
/// 0.85 / 0.6, confirmed by sampling MobileSMS bubbles under the header);
/// the ramp keeps the same shape.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationTopEdgeGeometry {
    /// (offset from the header's bottom, wash opacity) in light mode.
    public static let lightStops: [(CGFloat, CGFloat)] = [
        (-74, 0.855), (-49, 0.78), (-34, 0.66), (-19, 0.47), (-4, 0.26),
        (6, 0.17), (16, 0.08), (26, 0.04), (41, 0.01), (46, 0),
    ]
    public static let extent: CGFloat = 46
    public static let lightPeak: CGFloat = 0.855
    public static let darkPeak: CGFloat = 0.60

    public static func stops(dark: Bool) -> [(CGFloat, CGFloat)] {
        let scale = dark ? darkPeak / lightPeak : 1
        return lightStops.map { ($0.0, $0.1 * scale) }
    }

    /// The wash as gradient stops over a span of `height` points whose
    /// header bottom sits at `headerBottom`: unit locations and wash opacity,
    /// flat at the top and clear from `extent` below the header down.
    public static func ramp(height: CGFloat, headerBottom: CGFloat, dark: Bool) -> [(location: CGFloat, wash: CGFloat)] {
        guard height > 0 else { return [] }
        let stops = stops(dark: dark)
        var ramp = [(location: CGFloat(0), wash: stops[0].1)]
        for (offset, alpha) in stops {
            ramp.append((min(1, max(0, headerBottom + offset) / height), alpha))
        }
        if ramp[ramp.count - 1].location < 1 { ramp.append((1, 0)) }
        return ramp
    }
}

extension ConversationHeaderGeometry {
    /// Landscape iPhone (compact height). Messages (iOS 27.0, iPhone 17 Pro
    /// Max) shrinks its bar to 54 pt starting 24 pt down (the window's safe
    /// top is 0 there) and seats a 44 pt avatar with the bold name inline to
    /// its right, no capsule: name 12 pt after the avatar, the compact
    /// chevron 4 pt after the name, 8 pt of trailing padding, the group
    /// centered and on the avatar's center line.
    public struct CompactLayout: Equatable, Sendable {
        public var barTop: CGFloat
        public var barHeight: CGFloat
        public var avatar: CGRect
        public var name: CGRect
        public var chevron: CGRect
    }

    public static let compactBarTop: CGFloat = 24
    public static let compactBarHeight: CGFloat = 54
    public static let compactAvatarSize: CGFloat = 44
    public static let compactNameGap: CGFloat = 12
    public static let compactChevronGap: CGFloat = 4
    public static let compactTrailingPadding: CGFloat = 8

    public static func compactLayout(width: CGFloat, safeTop: CGFloat, nameSize: CGSize, chevronSize: CGSize) -> CompactLayout {
        let top = max(safeTop, compactBarTop)
        let groupWidth = compactAvatarSize + compactNameGap + nameSize.width + compactChevronGap + chevronSize.width + compactTrailingPadding
        let avatar = CGRect(x: width / 2 - groupWidth / 2, y: top, width: compactAvatarSize, height: compactAvatarSize)
        let name = CGRect(x: avatar.maxX + compactNameGap, y: avatar.midY - nameSize.height / 2, width: nameSize.width, height: nameSize.height)
        let chevron = CGRect(x: name.maxX + compactChevronGap, y: avatar.midY - chevronSize.height / 2, width: chevronSize.width, height: chevronSize.height)
        return CompactLayout(barTop: top, barHeight: compactBarHeight, avatar: avatar, name: name, chevron: chevron)
    }
}
