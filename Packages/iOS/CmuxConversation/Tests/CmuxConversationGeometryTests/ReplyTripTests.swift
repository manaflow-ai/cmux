import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Frames of Messages on an iPhone 17 Pro Max (956 pt tall, 60 fps): a
/// 62 pt incoming bubble swiped 64 pt right at y 401 travels 128.66 pt
/// down into the reply thread, then back up when the thread closes.
/// Positions are relative to where each trip starts.
@Suite struct ReplyTripTests {
    static let frame = 1.0 / 60

    static let deviceIntoY: [CGFloat] = [0, 18.04, 31.84, 43.9, 54.47, 63.74, 72.01, 79.11, 85.33, 90.69, 95.44, 99.62, 103.25,
                                         106.36, 109.2, 111.62, 113.71, 115.62, 117.25, 118.67, 119.94, 121.0, 121.97, 122.77,
                                         123.53, 124.16, 124.7, 125.22, 125.66, 126.01, 126.33]
    static let deviceIntoX: [CGFloat] = [64, 64, 73.67, 76.33, 75.67, 72.67, 68.33, 63, 57.67, 52.34, 47.34, 42.33, 38, 33.67, 30,
                                         26.67, 23.67, 20.67, 18.33, 16, 14.33, 12.33, 11, 9.67, 8.33, 7.33, 6.33, 5.67, 5, 4.33, 3.67]
    static let deviceBackY: [CGFloat] = [0, -24.38, -42.04, -56.7, -68.92, -79.02, -87.41, -94.39, -100.23, -105.02, -109.02,
                                         -112.35, -115.1, -117.39, -119.33, -120.92, -122.25, -123.32, -124.25, -124.99, -125.61,
                                         -126.13, -126.57, -126.93, -127.21, -127.46, -127.65, -127.81, -127.99]

    @Test func swipedBubbleFollowsMessagesIntoTheThreadWithinAPoint() {
        let easing = ConversationReplyMotion.threadEasing(startCenterY: 401, itemHeight: 62, viewHeight: 956, animatingOut: false)
        var trip = ReplyTrip(startY: 0, targetY: 128.66, initialOffsetX: 64, easing: easing,
                             snapDistance: ConversationReplyMotion.snapDistance(scale: 3, animatingOut: false))
        for index in Self.deviceIntoY.indices {
            if index > 0 { trip.step(frameDuration: Self.frame) }
            #expect(abs(trip.y - Self.deviceIntoY[index]) < 1, "frame \(index): y \(trip.y) vs \(Self.deviceIntoY[index])")
            #expect(abs(trip.offsetX - Self.deviceIntoX[index]) < 1, "frame \(index): x \(trip.offsetX) vs \(Self.deviceIntoX[index])")
        }
        while !trip.isResting { trip.step(frameDuration: Self.frame) }
        // Messages lands it 0.25 px out and drops the swing the frame after.
        #expect(trip.stepCount < 60)
    }

    @Test func rowFollowsMessagesBackWithinAPointAndSnapsFrom2Pixels() {
        let easing = ConversationReplyMotion.threadEasing(startCenterY: 527, itemHeight: 62, viewHeight: 956, animatingOut: true)
        var trip = ReplyTrip(startY: 0, targetY: -128.67, initialOffsetX: 0, easing: easing,
                             snapDistance: ConversationReplyMotion.snapDistance(scale: 3, animatingOut: true))
        for index in Self.deviceBackY.indices {
            if index > 0 { trip.step(frameDuration: Self.frame) }
            #expect(abs(trip.y - Self.deviceBackY[index]) < 1, "frame \(index): y \(trip.y) vs \(Self.deviceBackY[index])")
        }
        // 0.68 pt left: Messages lands it on the next frame.
        trip.step(frameDuration: Self.frame)
        #expect(trip.y == -128.67)
    }

    /// A swiped bottom bubble whose thread slot is where it already sits
    /// still walks its swing home rather than jumping back when it lands.
    @Test func swingWalksHomeEvenWhenTheRowHasNowhereToGo() {
        var trip = ReplyTrip(startY: 0, targetY: 0.05, initialOffsetX: 30, easing: 0.88, snapDistance: 0.25 / 3)
        trip.step(frameDuration: Self.frame)
        #expect(trip.y == 0.05)
        #expect(abs(trip.offsetX - (30 - 6 * ReplyTrip.firstStepFrames)) < 0.001)
        trip.step(frameDuration: Self.frame)
        #expect(abs(trip.offsetX - (30 - 6 * ReplyTrip.firstStepFrames - 6)) < 0.001)
        #expect(!trip.isResting)
    }

    @Test func shortTripWalksTheSwingBack6PointsAFrame() {
        var trip = ReplyTrip(startY: 0, targetY: 1, initialOffsetX: 30, easing: 0.89, snapDistance: 0.25 / 3)
        trip.step(frameDuration: Self.frame)
        #expect(abs(trip.offsetX - (30 - 6 * ReplyTrip.firstStepFrames)) < 0.001)
    }
}
