import AppKit
@testable import CmuxNextWakeups
import Testing

/// p03-rendering-113: the family is the one reader of AppKit's occlusion. It observes each window's
/// occlusion notice once, through the window's `WindowEvents`, and every reader subscribes to it, so a
/// window's notice reaches that window's subscribers once, in stage order, and no other window's.
@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowOcclusionFamilySystemTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The acceptance: a fake notice of one window reaches its subscribers once and no other window's.
    @Test func aWindowsNoticeReachesItsSubscribersOnceAndNoOtherWindows() {
        let center = NotificationCenter()
        let first = Self.window(), second = Self.window()
        let firstEvents = WindowEvents(window: first, center: center)
        let firstFamily = WindowOcclusionFamily(window: first, events: firstEvents)
        let secondEvents = WindowEvents(window: second, center: center)
        let secondFamily = WindowOcclusionFamily(window: second, events: secondEvents)
        var heard: [String] = []
        let monitor = firstFamily.subscribe(.diagnostics, owner: "monitor") { _ in heard.append("first monitor") }
        let surface = firstFamily.subscribe(.content, owner: "surface") { _ in heard.append("first surface") }
        let other = secondFamily.subscribe(.content, owner: "surface") { _ in heard.append("second surface") }

        center.post(name: WindowOcclusionFamily.systemNotice, object: first)

        #expect(heard == ["first surface", "first monitor"], "once each, content first, nothing for the other window")
        #expect(firstFamily.systemChanges == 1)
        #expect(secondFamily.systemChanges == 0)
        #expect(firstFamily.flips == 0, "an AppKit notice is no cover flip")
        #expect(firstEvents.subscriberCount(WindowOcclusionFamily.systemNotice) == 1, "one observer, however many readers")
        withExtendedLifetime((monitor, surface, other, secondEvents)) {}
    }

    /// A reader reads AppKit's state and the source's together: either one hides the window.
    @Test func onScreenNeedsAppKitAndTheSource() {
        let window = Self.window()
        var appKitVisible = true
        let family = WindowOcclusionFamily(window: window, systemVisible: { _ in appKitVisible })
        #expect(family.isOnScreen)
        family.set(occluded: true)
        #expect(!family.isOnScreen, "covered by an opaque cmux window")
        family.set(occluded: false)
        appKitVisible = false
        #expect(!family.isSystemVisible)
        #expect(!family.isOnScreen, "AppKit says none of it shows")
    }

    /// The static read makes no family, and a window with no family reads AppKit's answer.
    @Test func theStaticReadMakesNoFamily() {
        let window = Self.window()
        #expect(WindowOcclusionFamily.isOnScreen(window) == WindowOcclusionFamily.appKitVisible(window))
        #expect(WindowOcclusionFamily.installed(on: window) == nil)
        let family = WindowOcclusionFamily.of(window)
        family.set(occluded: true)
        #expect(!WindowOcclusionFamily.isOnScreen(window), "an installed family's cover counts")
    }

    /// An owner that watches windows it does not own hears every window's notice, family or not.
    @Test func anAppWideObserverHearsEveryWindow() {
        let center = NotificationCenter()
        let first = Self.window(), second = Self.window()
        var heard: [ObjectIdentifier] = []
        let observation = WindowOcclusionFamily.observeSystemChanges(center: center) { heard.append(ObjectIdentifier($0)) }
        center.post(name: WindowOcclusionFamily.systemNotice, object: first)
        center.post(name: WindowOcclusionFamily.systemNotice, object: second)
        center.post(name: WindowOcclusionFamily.systemNotice, object: nil)
        #expect(heard == [ObjectIdentifier(first), ObjectIdentifier(second)])
        withExtendedLifetime(observation) {}
    }

    /// A released subscription hears nothing more; the family keeps observing for the others.
    @Test func aReleasedSubscriberHearsNothing() {
        let center = NotificationCenter()
        let window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let family = WindowOcclusionFamily(window: window, events: events)
        var heard = 0
        var watch: WindowOcclusionSubscription? = family.subscribe(.content, owner: "view") { _ in heard += 1 }
        center.post(name: WindowOcclusionFamily.systemNotice, object: window)
        watch = nil
        center.post(name: WindowOcclusionFamily.systemNotice, object: window)
        #expect(heard == 1)
        #expect(family.systemChanges == 2)
        #expect(watch == nil)
        withExtendedLifetime(events) {}
    }
}
