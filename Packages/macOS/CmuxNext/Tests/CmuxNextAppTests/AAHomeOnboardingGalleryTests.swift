import AppKit
import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import CmuxTheme
import CryptoKit
import ImageIO
import Testing

/// Actual empty Home transcript, not the web HomeInbox or an account-state mock.
/// The manifest explicitly lists axes this fixture cannot exercise.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAHomeOnboardingGalleryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func captureFreshHome() async throws {
        _ = NSApplication.shared
        try #require(NSScreen.main != nil, "A fleet GUI session is required")
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "native-home-onboarding-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var captures: [[String: Any]] = []
        for width in [460, 280] {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                captures.append(try await capture(width: width, mode: mode, theme: theme, dark: dark, out: out))
            }
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1, "surface": "native-home", "scene": "empty-chief-transcript",
            "sourceSha": try sourceSHA(), "captures": captures,
            "fixture": ["source": "EmptyChiefSource", "messages": 0, "agents": 0, "workspaces": 0],
            "coverage": "component-baseline-only",
            "unsupportedAxes": ["harness-auth", "provider-account-tier", "cmux-identity", "cmux-plan", "machine-placement"],
            "limitation": "HomeNativeTranscriptView consumes conversation state. This fixture does not construct AppServices or establish account, entitlement, harness authentication or cloud execution. No matrix cell is marked passed from these captures."
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appending(path: "manifest.json"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "native-home-onboarding-gallery.tar", "native-home-onboarding-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    private func capture(width: Int, mode: String, theme: String, dark: Bool, out: URL) async throws -> [String: Any] {
        let source = EmptyChiefSource(), id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let cache = FileManager.default.temporaryDirectory.appending(path: "home-audit-\(UUID())")
        let store = HomeStore(source: source, blobCacheDirectory: cache)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            view.stop()
            store.stop()
            window.close()
            try? FileManager.default.removeItem(at: cache)
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = window.appearance
        window.contentView = view
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(view)
        await view.binding.opened()
        view.setFirstRunStarters(HomeStarterContext())
        view.firstRun.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: nil)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        for child in AANestedGroupsGalleryTests.all(view) { child.needsDisplay = true; child.displayIfNeeded() }
        CATransaction.flush()
        try #require(!view.firstRun.isHidden, "Fixture must display the actual empty Chief panel")
        let before = frames(view)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let after = frames(view)
        #expect(before == after, "AX frames must remain stable across the image")
        let image = try #require(rep.cgImage)
        let name = "home-\(width)-\(mode).png"
        let path = out.appending(path: name)
        let dest = try #require(CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        try #require(CGImageDestinationFinalize(dest))
        let scale = Double(image.width) / view.bounds.width
        let actionRects = view.firstRun.actionRows.map { view.convert($0.bounds, from: $0) }
        var violations: [String] = []
        for (index, rect) in actionRects.enumerated() {
            if !view.bounds.insetBy(dx: -1, dy: -1).contains(rect) { violations.append("action-\(index)-outside-viewport") }
            if rect.width <= 0 || rect.height <= 0 { violations.append("action-\(index)-empty-frame") }
        }
        if let first = actionRects.first, actionRects.contains(where: { abs($0.minX - first.minX) > 1 }) {
            violations.append("action-leading-edges-differ-over-1pt")
        }
        #expect(violations.isEmpty, "home-\(width)-\(mode) geometry: \(violations)")
        return ["scene": "empty-chief-transcript", "requestedAppearance": mode,
                "effectiveAppearance": view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                "theme": theme, "file": name, "sha256": SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined(),
                "pixels": [image.width, image.height], "scale": scale,
                "axCoordinateSpace": "NSAccessibility-screen", "axFrames": before.map(box),
                "viewCoordinateSpace": "view-local-points", "actionRects": actionRects.map(box),
                "firstRunRect": box(view.firstRun.frame), "violations": violations,
                "geometryResult": violations.isEmpty ? "pass" : "fail",
                "matrixResult": "unsupported-fixture"]
    }

    private func frames(_ view: HomeNativeTranscriptView) -> [NSRect] {
        view.firstRun.actionRows.map { $0.accessibilityFrame() }
    }

    private func box(_ rect: NSRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    private func sourceSHA() throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = AANestedGroupsGalleryTests.repoRoot
        process.arguments = ["rev-parse", "HEAD"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try #require(String(data: data, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
