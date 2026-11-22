import AppKit
@testable import CmuxNextDevices
import CryptoKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxScreenKit
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// The `macScreen.viewerLook` gallery (Leo 2026-11-21: "our screen shared screen looks like ass"): the real
/// `MacScreenPaneView` drawn offscreen with no session or network, in every viewer look, in every state the pane
/// shows, light and dark (Soft Blue), wide (1280x800) and, in dark, narrow (520x700). The pane is driven through its
/// models (`MacScreenSession.showPreviewState`, the hub phase); the remote frame is a synthetic desktop image laid
/// in the video view, letterboxed by the pane's own fit. Written as PNGs under `mac-screen-viewer-gallery/` in the
/// package, one `<look>-all.png` contact sheet per look, and bundled to `mac-screen-viewer-gallery.tar`. Runs only
/// with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AAMacScreenViewerGalleryTests {
    struct State {
        let name: String
        let scope: SessionScope
        let phase: MacScreenSession.Phase
        var cause: MacScreenSession.FailureCause?
        var linkConnected = false
        var hasFrame = false
        var capturesKeyboard = false
        /// A quality readout state: the readout drawn, over an ultra session's numbers.
        var readout: MacScreenQualityReadout?
        /// A bar state: the floating bar's arrangement, live in control over an ultra session.
        var bar: MacScreenToolbarBar?
        /// A host too old to name its profile (no `encode_profile`): the rate shows with no profile word.
        var oldHost = false
        /// The toolbar's Record button shows a file being written (red, Stop Recording).
        var recording = false
    }

    /// An ultra session (D10): the host streams at 148 Mbps, 120 of 120 fps, direct, 3 ms.
    static var ultraStats: MacScreenSession.LiveStats {
        var stats = MacScreenSession.LiveStats()
        stats.fps = 119.6
        stats.targetFps = 120
        stats.latencyMs = 3
        stats.encoding = "HEVC"
        stats.hostKbps = 148_000
        stats.lossPercent = 0.1
        stats.encodeMsP50 = 2.4
        stats.encodeProfile = "ultra"
        return stats
    }

    static func stats(for state: State) -> MacScreenSession.LiveStats {
        var stats = ultraStats
        if state.oldHost { stats.encodeProfile = nil }
        return stats
    }

    /// The `macScreen.qualityReadout` variants (R1 inline, R2 chip, R3 stats panel), each live with the ultra numbers.
    static let readoutStates: [State] = MacScreenQualityReadout.allCases.map {
        State(name: "readout-\($0.rawValue)", scope: .full, phase: .connected, hasFrame: true, readout: $0)
    }

    /// The `macScreen.toolbarBar` variants (Leo 2026-11-22, of the two-row bar: "this is still bad looking"), each live
    /// in control with the ultra numbers; `stacked` is the bar he saw.
    static let barStates: [State] = MacScreenToolbarBar.allCases.map {
        State(name: "bar-\($0.rawValue)", scope: .full, phase: .connected, hasFrame: true, readout: .inline, bar: $0)
    } + [State(name: "bar-row-oldhost", scope: .full, phase: .connected, hasFrame: true, readout: .inline, bar: .row,
               oldHost: true)]

    /// Leo's pane (the bar he saw stacked) and a narrow one.
    static let barWidths: [CGSize] = [CGSize(width: 720, height: 450), CGSize(width: 480, height: 450)]

    static let states: [State] = [
        State(name: "connecting", scope: .full, phase: .connecting),
        State(name: "live", scope: .full, phase: .connected, hasFrame: true),
        State(name: "live-recording", scope: .full, phase: .connected, hasFrame: true, recording: true),
        State(name: "live-view-only", scope: .view, phase: .connected, hasFrame: true),
        State(name: "live-control", scope: .full, phase: .connected, hasFrame: true, capturesKeyboard: true),
        State(name: "no-picture", scope: .view, phase: .failed(message: "", needsSignIn: false), linkConnected: true),
        State(name: "host-asleep", scope: .view, phase: .failed(message: "", needsSignIn: false),
              cause: .host("the display is asleep or the screen is locked")),
        State(name: "error-long", scope: .full, phase: .failed(message: "", needsSignIn: false),
              cause: .link("no route to host after 6 attempts: the relay at turn.example.com:3478 refused the credentials, the direct path timed out and "
                  + "the tailnet address did not answer. Check that the other Mac is awake, signed in to cmux and on a network.")),
    ]

    static let wide = CGSize(width: 1280, height: 800)
    static let narrow = CGSize(width: 520, height: 700)
    /// The remote display's pixels (16:10), so the picture letterboxes in the 1280x800 pane's area below the toolbar.
    static let remotePixels = CGSize(width: 2560, height: 1600)

    /// A plausible remote desktop: wallpaper gradient, menu bar, two windows and a Dock.
    static func desktop() -> NSImage {
        let size = remotePixels
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.12, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.55, green: 0.22, blue: 0.62, alpha: 1),
                                NSColor(srgbRed: 0.98, green: 0.52, blue: 0.36, alpha: 1)])?.draw(in: rect, angle: 35)
            func panel(_ frame: CGRect, _ fill: NSColor, radius: CGFloat = 24) {
                fill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            panel(CGRect(x: 0, y: rect.height - 48, width: rect.width, height: 48), NSColor(white: 1, alpha: 0.25), radius: 0)
            for index in 0 ..< 6 { panel(CGRect(x: 24 + CGFloat(index) * 96, y: rect.height - 34, width: 64, height: 20), NSColor(white: 1, alpha: 0.7), radius: 10) }
            panel(CGRect(x: 220, y: 560, width: 1200, height: 800), NSColor(white: 0.97, alpha: 1))
            panel(CGRect(x: 220, y: 1260, width: 1200, height: 100), NSColor(white: 0.88, alpha: 1), radius: 24)
            panel(CGRect(x: 260, y: 600, width: 320, height: 620), NSColor(white: 0.92, alpha: 1), radius: 16)
            panel(CGRect(x: 1000, y: 180, width: 1180, height: 760), NSColor(white: 0.09, alpha: 0.94))
            for line in 0 ..< 9 { panel(CGRect(x: 1048, y: 860 - CGFloat(line) * 72, width: 300 + CGFloat((line * 137) % 600), height: 24), NSColor(srgbRed: 0.4, green: 0.9, blue: 0.5, alpha: 0.85), radius: 8) }
            panel(CGRect(x: 760, y: 24, width: 1040, height: 128), NSColor(white: 1, alpha: 0.28), radius: 40)
            for index in 0 ..< 9 {
                panel(CGRect(x: 800 + CGFloat(index) * 108, y: 44, width: 88, height: 88),
                      NSColor(hue: CGFloat(index) / 9, saturation: 0.6, brightness: 0.95, alpha: 1), radius: 20)
            }
            return true
        }
    }

    static func render(look: MacScreenViewerLook, state: State, size: CGSize, theme: String, dark: Bool) async throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: size.width, height: size.height), styleMask: [.borderless],
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
        // This Mac's own hub link is up: a failed state then shows its own cause (an asleep host, a link error), not
        // "This Mac lost its connection to the device hub", which every failed state showed with no hub at all.
        let hub = await connectedHub()
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { hub }
        #expect(viewer.hubConnected)
        viewer.phase = .streaming(sessionID: "gallery-session", scope: state.scope)
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio MacBook Pro", preferences: ScreenPreferences(), viewerLook: look)
        defer { pane.close() }
        pane.model.hasFrame = state.hasFrame
        pane.model.qualityReadoutOverride = state.readout
        pane.model.toolbarBarOverride = state.bar
        // The readout states show the host's numbers; the stats panel is the one Show Stats turns on.
        if state.readout == .hud { pane.session?.preferences.showStats = true }
        if state.recording {
            pane.model.recording.file = MacScreenRecording.fileURL(device: "Studio MacBook Pro", at: Date(timeIntervalSince1970: 1_795_320_000))
            pane.model.recording.startedAt = Date(timeIntervalSince1970: 1_795_320_000)
        }
        pane.session?.showPreviewState(phase: state.phase, failureCause: state.cause, linkConnected: state.linkConnected,
                                       frameSize: state.hasFrame ? remotePixels : .zero,
                                       stats: state.readout == nil ? nil : stats(for: state), path: state.readout == nil ? nil : "Direct")
        pane.view.frame = root.bounds
        pane.view.autoresizingMask = [.width, .height]
        root.addSubview(pane.view)
        window.orderFrontRegardless()
        // The toolbar and the card follow the models through Observation (main-actor tasks): let them run.
        for _ in 0 ..< 100 { await Task.yield() }
        // The keyboard state goes in after those tasks: each syncs the input gate, which puts back the fixture's
        // released keyboard (`capturesKeyboard` false). Nothing syncs it again, so the control states keep their marks.
        pane.model.capturesKeyboard = state.capturesKeyboard
        for _ in 0 ..< 20 { await Task.yield() }
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        if state.hasFrame {
            // The pane's first subview is its video view; the synthetic frame fills it, so the pane's own fit letterboxes it.
            let video = try #require(pane.view.subviews.first)
            let picture = NSImageView(image: desktop())
            picture.imageScaling = .scaleAxesIndependently
            picture.frame = video.bounds
            picture.autoresizingMask = [.width, .height]
            video.addSubview(picture)
        }
        pane.view.chrome.toolbar.resolveColors()
        pane.view.chrome.card.resolveColors()
        pane.view.chrome.statusStrip?.bar.resolveColors()
        pane.view.chrome.statusStrip?.body.resolveColors()
        for _ in 0 ..< 20 { await Task.yield() }
        pane.view.layoutSubtreeIfNeeded()
        // The picture shows the state named: a control state with its controlling marks, the rest without.
        try #require(pane.model.capturesKeyboard == state.capturesKeyboard, "\(look.rawValue)-\(state.name): capturesKeyboard")
        if state.recording {
            // The Record button is drawn red with its Stop Recording tip, as while a file is being written.
            // In every look, the pill included; a compact bar folds it into More.
            let views = AANestedGroupsGalleryTests.all(root)
            let record = try #require(views.first { $0.accessibilityIdentifier() == "macScreen.record" })
            let more = try #require(views.first { $0.accessibilityIdentifier() == "macScreen.more" })
            #expect(!record.isHidden || !more.isHidden, "\(look.rawValue)-\(state.name): Record reachable")
            if size == Self.wide { #expect(!record.isHidden, "\(look.rawValue)-\(state.name): Record shown") }
            #expect(pane.model.recording.isRecording)
        }
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// A hub whose socket says connected (no network: its account token never resolves, so its reads fail at once).
    static func connectedHub() async -> DeviceHub {
        let identity = DeviceIdentity(deviceID: UUID(), keys: GalleryKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { throw CancellationError() })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Gallery Mac")
        await hub.handle(.state(.connected))
        return hub
    }

    nonisolated private struct GalleryKeys: DeviceKeyMaterial {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
        var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
        func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
        func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
            var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                               encapsulatedKey: encapsulatedKey)
            return try recipient.open(ciphertext)
        }
    }

    /// Wide light and dark for every state on one sheet (half size, light left, dark right).
    static func sheet(_ images: [(light: CGImage, dark: CGImage)]) throws -> CGImage {
        let cellWidth = Int(wide.width) / 2, cellHeight = Int(wide.height) / 2, gap = 16
        let ctx = try #require(CGContext(data: nil, width: 2 * cellWidth + gap, height: images.count * (cellHeight + gap) - gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for (row, pair) in images.enumerated() {
            let y = ctx.height - (row + 1) * cellHeight - row * gap
            ctx.draw(pair.light, in: CGRect(x: 0, y: y, width: cellWidth, height: cellHeight))
            ctx.draw(pair.dark, in: CGRect(x: cellWidth + gap, y: y, width: cellWidth, height: cellHeight))
        }
        return try #require(ctx.makeImage())
    }

    /// Images stacked top to bottom, left aligned, on gray.
    static func strip(_ images: [CGImage]) throws -> CGImage {
        let gap = 12
        let width = images.map(\.width).max() ?? 1
        let height = images.reduce(0) { $0 + $1.height + gap } - gap
        let ctx = try #require(CGContext(data: nil, width: width, height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var top = ctx.height
        for image in images {
            top -= image.height
            ctx.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
            top -= gap
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-viewer-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in MacScreenViewerLook.allCases {
            var pairs: [(light: CGImage, dark: CGImage)] = []
            for state in Self.states {
                var pair: [CGImage] = []
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try await Self.render(look: look, state: state, size: Self.wide, theme: theme, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(state.name)-\(mode).png"))
                    pair.append(image)
                }
                pairs.append((pair[0], pair[1]))
                let narrow = try await Self.render(look: look, state: state, size: Self.narrow, theme: "Soft Blue", dark: true)
                try AAGroupHeaderDensityGalleryTests.write(narrow, to: out.appending(path: "\(look.rawValue)-\(state.name)-narrow-dark.png"))
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(pairs), to: out.appending(path: "\(look.rawValue)-all.png"))
        }
        // The quality readouts, in the default look and the bar look (where the bar has room for the full line).
        for look in [MacScreenViewerLook.a, .current] {
            var pairs: [(light: CGImage, dark: CGImage)] = []
            for state in Self.readoutStates {
                var pair: [CGImage] = []
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try await Self.render(look: look, state: state, size: Self.wide, theme: theme, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(state.name)-\(mode).png"))
                    pair.append(image)
                }
                pairs.append((pair[0], pair[1]))
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(pairs), to: out.appending(path: "\(look.rawValue)-readouts.png"))
        }
        // The bar variants at Leo's width and a narrow one, whole and as one sheet of the bars alone (top band).
        var bars: [CGImage] = []
        for state in Self.barStates {
            for size in Self.barWidths {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try await Self.render(look: .a, state: state, size: size, theme: theme, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "a-\(state.name)-\(Int(size.width))-\(mode).png"))
                    let scale = CGFloat(image.height) / size.height
                    bars.append(try #require(image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: 56 * scale))))
                }
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try Self.strip(bars), to: out.appending(path: "a-bars.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-viewer-gallery.tar", "mac-screen-viewer-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
