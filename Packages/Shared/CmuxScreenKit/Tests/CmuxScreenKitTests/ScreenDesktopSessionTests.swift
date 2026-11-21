import CmuxScreenKit
import CoreGraphics
import QuartzCore
import Testing

/// A desktop stream (the iPhone's cmux.rd/1 viewer of a Linux desktop) under
/// ``ScreenSession``: the session's input arrives in stream pixels and X terms, its
/// welcome connects the session, and a drop goes to the owner's reattach.
@MainActor struct ScreenDesktopSessionTests {
    @MainActor final class Recorder: ScreenDesktopStream {
        let layer = CALayer()
        var sent: [ScreenDesktopInput] = []
        var keyframes = 0
        var closed = false
        var events: (@MainActor (ScreenDesktopEvent) -> Void)?
        func start(_ events: @escaping @MainActor (ScreenDesktopEvent) -> Void) { self.events = events }
        func send(_ input: ScreenDesktopInput) { sent.append(input) }
        func requestKeyframe() { keyframes += 1 }
        func sample() -> ScreenDesktopSample { ScreenDesktopSample() }
        func close() { closed = true }
    }

    private func connected() -> (ScreenSession, Recorder) {
        let desktop = Recorder()
        var made = false
        let session = ScreenSession(title: "Box", desktop: {
            defer { made = true }
            return made ? nil : desktop
        })
        session.connect()
        desktop.events?(.connected(width: 1920, height: 1080))
        session.setStreamFrameSize(CGSize(width: 1920, height: 1080))
        return (session, desktop)
    }

    @Test func welcomeConnectsAndInputGoesInStreamPixelsAndXTerms() {
        let (session, desktop) = connected()
        #expect(session.isDesktop && !session.isStream)
        guard case let .connected(info) = session.phase else { Issue.record("not connected"); return }
        #expect((info.width, info.height) == (1920, 1080))

        session.movePointer(to: CGPoint(x: 100.4, y: 2000))
        session.click(.right)
        session.scroll(dx: 0, dy: 2)
        session.tap(VNCKeysym(rawValue: 0x63), modifiers: [.control])
        session.type("hi")
        session.refresh()
        #expect(desktop.sent == [
            .pointer(x: 100, y: 1079), // clamped to the stream
            .pointer(x: 100, y: 1079), .button(3, down: true), .button(3, down: false),
            // RFB's wheel up (positive) is rd's up (negative), in hundredths of a line.
            .pointer(x: 100, y: 1079), .scroll(dx: 0, dy: -200),
            .keysym(.control, down: true), .keysym(VNCKeysym(rawValue: 0x63), down: true),
            .keysym(VNCKeysym(rawValue: 0x63), down: false), .keysym(.control, down: false),
            .type("hi"),
        ])
        #expect(desktop.keyframes == 1)
    }

    @Test func aPictureReachesTheViewAndADropGoesToTheOwner() {
        let (session, desktop) = connected()
        var pictures: [CGSize] = []
        session.onDesktopPicture = { layer, size in
            #expect(layer === desktop.layer)
            pictures.append(size)
        }
        desktop.events?(.picture(CGSize(width: 1280, height: 720)))
        #expect(pictures == [CGSize(width: 1280, height: 720)])
        #expect(session.desktopPicture?.size == CGSize(width: 1280, height: 720))
        desktop.events?(.path(relayed: true))
        #expect(session.pathLabel == "Video · Relay")

        session.reconnectLimit = 0
        var dropped = 0
        session.onDropped = {
            dropped += 1
            return true
        }
        desktop.events?(.ended("the host closed the link"))
        #expect(dropped == 1)
        #expect(desktop.closed)
        #expect(session.isReconnecting && session.phase == .connecting)
        // The last picture stays until the next stream shows one.
        #expect(session.desktopPicture?.layer === desktop.layer)
    }

    @Test func aStreamThatEndsBeforeItsWelcomeFails() {
        let desktop = Recorder()
        let session = ScreenSession(title: "Box", desktop: { desktop })
        session.connect()
        desktop.events?(.ended("refused"))
        guard case let .failed(message, _) = session.phase else { Issue.record("not failed"); return }
        #expect(message.contains("refused"))
        #expect(desktop.closed && session.desktop == nil)
    }
}
