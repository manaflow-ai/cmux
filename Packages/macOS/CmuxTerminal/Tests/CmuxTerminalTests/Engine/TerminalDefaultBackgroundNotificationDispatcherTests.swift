import AppKit
import CmuxFoundation
import Testing

@testable import CmuxTerminal

/// Verifies the coalescing contract of
/// ``TerminalDefaultBackgroundNotificationDispatcher`` drained out of the
/// `GhosttyApp` god type: a burst collapses to the latest payload, separate
/// bursts each post once, and the posted `userInfo` carries the frozen
/// appearance keys.
@MainActor
struct TerminalDefaultBackgroundNotificationDispatcherTests {
    @Test func signalCoalescesBurstToLatestBackground() async {
        let dark = try! #require(NSColor(hex: "#272822"))
        let light = try! #require(NSColor(hex: "#FDF6E3"))

        var posted: [[AnyHashable: Any]] = []
        await withCheckedContinuation { continuation in
            let dispatcher = TerminalDefaultBackgroundNotificationDispatcher(
                delay: 0.01,
                postNotification: { userInfo in
                    posted.append(userInfo)
                    continuation.resume()
                }
            )
            Self.signal(dispatcher, color: dark, opacity: 0.95, eventId: 1, source: "test.dark")
            Self.signal(dispatcher, color: light, opacity: 0.75, eventId: 2, source: "test.light")
        }

        #expect(posted.count == 1)
        #expect(
            (posted[0][TerminalDefaultBackgroundUserInfoKey.backgroundColor] as? NSColor)?.hexString() == "#FDF6E3"
        )
        #expect(
            Self.opacity(posted[0][TerminalDefaultBackgroundUserInfoKey.backgroundOpacity]) == 0.75
        )
        #expect(
            (posted[0][TerminalDefaultBackgroundUserInfoKey.backgroundEventId] as? NSNumber)?.uint64Value == 2
        )
        #expect(
            posted[0][TerminalDefaultBackgroundUserInfoKey.backgroundSource] as? String == "test.light"
        )
    }

    @Test func signalAcrossSeparateBurstsPostsMultipleNotifications() async {
        let dark = try! #require(NSColor(hex: "#272822"))
        let light = try! #require(NSColor(hex: "#FDF6E3"))

        var hexes: [String] = []
        await withCheckedContinuation { continuation in
            let dispatcher = TerminalDefaultBackgroundNotificationDispatcher(
                delay: 0.01,
                postNotification: { userInfo in
                    let hex = (userInfo[TerminalDefaultBackgroundUserInfoKey.backgroundColor] as? NSColor)?
                        .hexString() ?? "nil"
                    hexes.append(hex)
                    if hexes.count == 2 {
                        continuation.resume()
                    }
                }
            )
            Self.signal(dispatcher, color: dark, opacity: 1.0, eventId: 1, source: "test.dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.signal(dispatcher, color: light, opacity: 1.0, eventId: 2, source: "test.light")
            }
        }

        #expect(hexes == ["#272822", "#FDF6E3"])
    }

    private static func signal(
        _ dispatcher: TerminalDefaultBackgroundNotificationDispatcher,
        color: NSColor,
        opacity: Double,
        eventId: UInt64,
        source: String
    ) {
        dispatcher.signal(
            backgroundColor: color,
            opacity: opacity,
            eventId: eventId,
            source: source,
            foregroundColor: color,
            cursorColor: color,
            cursorTextColor: color,
            selectionBackground: color,
            selectionForeground: color
        )
    }

    private static func opacity(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return -1
    }
}
