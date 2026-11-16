import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextRemoteView
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// A Cloud machine's tab from Connect to its first frame, drawn the way the tab draws it: the
/// Connect card, then the pane's connecting card as the dial reports its steps. Counts the layout
/// shifts between steps: the card's frame or its title moving. Leo, 2026-11-16: "then the
/// Connecting to rd-demo-linux there's so many layout shifts with the bullshit display text in between :/".
/// With `CMUX_TEST_REQUIRE_GUI=1` each step is also a PNG under `remote-connect-sequence/`, bundled to
/// `remote-connect-sequence.tar`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AARemoteConnectSequenceTests {
    static let target = RemoteConnectionTarget.desktop(name: "rd-demo-linux", status: "Running", region: "us-west", isLive: true)
    static let size = NSSize(width: 720, height: 420)

    /// The steps, in order: the Connect card, then the connecting pane with each dial step.
    static let reasons: [String?] = [nil, "Waking the machine", "Opening the desktop, 12 s left", "Opening the desktop, 4 s left"]

    struct Step {
        var name: String
        var card: CGRect
        var title: CGRect
        var texts: [String]
    }

    static func steps(theme: String = "Soft Blue", dark: Bool = true, shots: URL? = nil) async throws -> [Step] {
        var steps: [Step] = []
        let gate = RemoteViewUnavailableView(content: .confirmTarget(target))
        steps.append(try await measure("0-connect", gate, theme: theme, dark: dark, shots: shots))
        for (index, reason) in reasons.enumerated() {
            let pane = RemoteDesktopPaneView(frame: NSRect(origin: .zero, size: size))
            prepare(pane)
            var state = RemotePaneState(hostName: target.name)
            state.viaCloudTunnel = true
            state.modeControl = .takeOver
            state.status = RemoteViewStatus(path: .viaCloudRegion, state: .connecting, connectingReason: reason)
            pane.render(state: state, settings: RemoteDesktopSettings())
            steps.append(try await measure("\(index + 1)-connecting", pane, theme: theme, dark: dark, shots: shots))
        }
        return steps
    }

    /// What the pane learns of the machine before it connects: the Connect card's target (`RemoteViewPageTab`).
    static func prepare(_ pane: RemoteDesktopPaneView) { pane.connectionTarget = target }

    static func measure(_ name: String, _ view: NSView, theme: String, dark: Bool, shots: URL?) async throws -> Step {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.contentBackground.withAlphaComponent(1) }.cgColor
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        // Twice: the text learns its width in the first pass and asks for its wrapped height in the second.
        root.layoutSubtreeIfNeeded()
        view.needsLayout = true
        root.layoutSubtreeIfNeeded()
        let visible = AANestedGroupsGalleryTests.all(root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
        // The card is the largest glass surface; the toolbar's pill is the other one.
        let card = try #require(visible.compactMap { $0 as? OverlaySurfaceView }.max { $0.bounds.height < $1.bounds.height },
                                "a card shows")
        let labels = AANestedGroupsGalleryTests.all(card).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? ChromeLabel }
            .filter { !$0.stringValue.isEmpty }
        let title = labels.first.map { $0.convert($0.bounds, to: root) } ?? .zero
        let step = Step(name: name, card: card.convert(card.bounds, to: root), title: title, texts: labels.map(\.stringValue))
        if let shots {
            window.orderFrontRegardless()
            for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
            var image: CGImage?
            for _ in 0..<20 where image == nil {
                CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(50))
                image = try? await window.screenshotImage()
            }
            let shot = try #require(image)
            let url = shots.appending(path: "step-\(name).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, shot, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        window.close()
        return step
    }

    /// A shift: the card's frame or its title moved between two steps.
    static func shifts(_ steps: [Step]) -> Int {
        zip(steps, steps.dropFirst()).filter { $0.card != $1.card || $0.title != $1.title }.count
    }

    @Test func countsLayoutShiftsFromConnectToTheFirstFrame() async throws {
        let steps = try await Self.steps()
        for step in steps {
            print("remote-connect-sequence \(step.name) card=\(step.card) title=\(step.title) texts=\(step.texts)")
        }
        print("remote-connect-sequence layout shifts: \(Self.shifts(steps)) over \(steps.count) steps")
        #expect(Self.shifts(steps) == 0, "one frame from Connect to the first frame")
        #expect(Set(steps.dropFirst().map(\.texts)).count == 1, "the dial's steps change no text")
        #expect(steps.allSatisfy { $0.texts.first == "rd-demo-linux" })
    }

    /// Cancel on the connecting card stops the connect, as the state card's Cancel did.
    @Test func theConnectingCardsCancelStopsTheConnect() throws {
        let pane = RemoteDesktopPaneView(frame: NSRect(origin: .zero, size: Self.size))
        Self.prepare(pane)
        var cancelled = 0
        pane.card.onCancel = { cancelled += 1 }
        var state = RemotePaneState(hostName: "vm-id-not-a-name")
        state.viaCloudTunnel = true
        pane.render(state: state, settings: RemoteDesktopSettings())
        let card = try #require(pane.connectingCard)
        #expect(pane.card.isHidden)
        #expect(RemoteViewUnavailableView.text(for: card.content).title == "rd-demo-linux", "the target's name, never the host id")
        card.onCancel?()
        #expect(cancelled == 1)
        state.status = RemoteViewStatus(path: .viaCloudRegion, state: .streaming)
        state.hasFrame = true
        pane.render(state: state, settings: RemoteDesktopSettings())
        #expect(pane.connectingCard == nil, "the first frame takes the card away")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderSequence() async throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "remote-connect-sequence")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try await Self.steps(shots: out)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "remote-connect-sequence.tar", "remote-connect-sequence"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
