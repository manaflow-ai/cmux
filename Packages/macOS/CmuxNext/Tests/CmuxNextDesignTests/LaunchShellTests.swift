import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The stage-0 launch window (cmuxterm-hq docs/design/launch-shell-first.md): what it holds for
/// the real window, in what order, and how a held event is rebuilt for it. The policy itself is
/// Rust's (cmux-launch-shell); these check the wiring.
@MainActor
@Suite(.closesItsWindows)
struct LaunchShellTests {
    private func key(_ characters: String, _ type: NSEvent.EventType = .keyDown, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    @Test func typedKeysAreHeldInArrivalOrderAndHoverPasses() throws {
        let window = LaunchShellWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), title: "stage 0")
        defer { window.close() }
        for c in ["l", "s", "\r"] { window.sendEvent(try key(c, window: window)) }
        window.sendEvent(try key("s", .keyUp, window: window))
        let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 0, pressure: 0))
        window.sendEvent(hover)
        let held = window.takeHeld()
        #expect(held.map(\.type) == [.keyDown, .keyDown, .keyDown, .keyUp])
        #expect(held.compactMap(\.characters) == ["l", "s", "\r", "s"])
        #expect(window.takeHeld().isEmpty)
    }

    @Test func theBareLaunchsContentTakesItsOwnKeys() throws {
        let window = LaunchShellWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), title: "stage 0")
        defer { window.close() }
        window.holdsInput = false
        window.sendEvent(try key("x", window: window))
        #expect(window.takeHeld().isEmpty)
    }

    @Test func aHeldEventIsRebuiltForTheRealWindow() throws {
        let stage0 = LaunchShellWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), title: "stage 0")
        let real = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                            backing: .buffered, defer: false)
        real.isReleasedWhenClosed = false // close() must not release what ARC releases too (signal 11)
        defer { stage0.close(); real.close() }
        let moved = try #require(try key("é", window: stage0).replayed(in: real))
        #expect(moved.windowNumber == real.windowNumber)
        #expect(moved.characters == "é" && moved.type == .keyDown)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 30), modifierFlags: [],
                                                    timestamp: 0, windowNumber: stage0.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        let movedClick = try #require(click.replayed(in: real))
        #expect(movedClick.windowNumber == real.windowNumber && movedClick.locationInWindow == CGPoint(x: 40, y: 30))
    }

    @Test func eventKindsMatchTheRustInputKinds() {
        #expect(NSEvent.EventType.keyDown.launchShellKind == 1 && NSEvent.EventType.keyUp.launchShellKind == 2)
        #expect(NSEvent.EventType.flagsChanged.launchShellKind == 3)
        #expect(NSEvent.EventType.rightMouseDown.launchShellKind == 4 && NSEvent.EventType.otherMouseUp.launchShellKind == 5)
        #expect(NSEvent.EventType.leftMouseDragged.launchShellKind == 6 && NSEvent.EventType.scrollWheel.launchShellKind == 7)
        #expect(NSEvent.EventType.mouseMoved.launchShellKind == 8 && NSEvent.EventType.appKitDefined.launchShellKind == 0)
    }

    @Test func theBuildKeyKeepsOnlyKeyCharacters() {
        #expect(LaunchShellPaths.build(info: ["CFBundleVersion": "4294", "CMUXCommit": "abc123"]) == "4294+abc123")
        #expect(LaunchShellPaths.build(info: ["CFBundleVersion": "1/../2 x"]) == "1..2x")
        #expect(LaunchShellPaths.build(info: [:]) == "unknown")
    }

    /// Labs > Show Window Shell at Launch reaches stage 0 as one file: on makes it (and its folder),
    /// off removes it, and both are idempotent.
    @Test func optInFileFollowsTheSetting() async throws {
        let folder = FileManager().temporaryDirectory.appending(path: "launch-shell-optin-\(UUID().uuidString)/com.example.app", directoryHint: .isDirectory)
        defer { try? FileManager().removeItem(at: folder.deletingLastPathComponent()) }
        #expect(!LaunchShellPaths(support: folder).isOptedIn)
        #expect(await LaunchShellPaths(support: folder).setOptedIn(true))
        #expect(await LaunchShellPaths(support: folder).setOptedIn(true))
        #expect(LaunchShellPaths(support: folder).isOptedIn)
        #expect(await LaunchShellPaths(support: folder).setOptedIn(false))
        #expect(await LaunchShellPaths(support: folder).setOptedIn(false))
        #expect(!LaunchShellPaths(support: folder).isOptedIn)
    }
}
