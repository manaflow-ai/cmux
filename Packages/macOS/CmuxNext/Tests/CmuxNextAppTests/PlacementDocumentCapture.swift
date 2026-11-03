import AppKit
import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Opt-in stills of the SAME committed document-order regression, including
/// its failing baseline. This helper never moves a row or changes expected order.
@MainActor
enum PlacementDocumentCapture {
    private nonisolated enum CaptureFailure: Error { case archiveExit(Int32) }

    static func captureIfRequested(controller: WindowController, committed: [String], expected: [String],
                                   original: [String], operations: [Data]) async throws {
        guard ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" else { return }
        try #require(!NSScreen.screens.isEmpty, "capture requires a managed fleet GUI display")
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let sidebar = controller.sidebar
        let actual = sidebar.model.selectableWorkspaces.map(\.id.rawValue)
        try #require(actual == committed, "capture must show the independently replayed, committed document")
        let titles = Dictionary(uniqueKeysWithValues: controller.services.daemon.store.workspaces.map { ($0.id, $0.name) })
        let expectedTitles = try committed.map { try #require(titles[$0]) }
        let moves = try operations.flatMap { try #require(JSONSerialization.jsonObject(with: $0) as? [[String: Any]]) }

        // Unique output per invocation: neither overwrite nor clear another run.
        let package = AANestedGroupsGalleryTests.packageRoot
        let env = ProcessInfo.processInfo.environment
        // Worker-owned env from the caller's --key: no custom env allowlist
        // changes. --artifact accepts a literal path, so it must be predictable.
        let captureID = env["CMUX_CI_STEP_KEY"] ?? UUID().uuidString.lowercased()
        try #require(!captureID.isEmpty && captureID.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }, "capture step key must contain only letters, digits, '.', '-' or '_'")
        let name = "placement-document-gallery-\(captureID)"
        let out = package.appending(path: name)
        let archive = package.appending(path: name + ".tar")
        try #require(!FileManager.default.fileExists(atPath: out.path) && !FileManager.default.fileExists(atPath: archive.path),
                     "choose a fresh capture ID; existing evidence must not be overwritten")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)

        // Only this disposable fixture window changes appearance. Its active
        // workspace can supply chrome colors, so override that effective scope.
        let scope = controller.themeScope.shown ?? controller.themeScope
        let savedSpec = scope.spec, savedInput = scope.input
        let savedWindowAppearance = window.appearance, savedRootAppearance = root.appearance
        let savedFrame = window.frame
        let wasVisible = window.isVisible
        defer {
            scope.setOverride(savedSpec, input: savedSpec == nil ? nil : savedInput, animated: false)
            window.appearance = savedWindowAppearance
            root.appearance = savedRootAppearance
            window.setFrame(savedFrame, display: false)
            if !wasVisible { window.orderOut(nil) }
        }
        window.setContentSize(NSSize(width: 900, height: 600))
        sidebar.restore(width: 300, hidden: false)
        window.orderFrontRegardless()

        for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
            let input = try AANestedGroupsGalleryTests.input(theme)
            scope.setOverride(ThemeSpec(theme), input: input, animated: false)
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            window.appearance = appearance
            root.appearance = appearance
            // No sleep or retry: force the existing native views to paint their
            // current model, then capture that surface in this main-actor turn.
            scope.perform {
                root.layoutSubtreeIfNeeded()
                sidebar.container.sidebarView.renderNow()
                for view in AANestedGroupsGalleryTests.all(root) {
                    view.layoutSubtreeIfNeeded()
                    view.layer?.removeAllAnimations()
                    view.needsDisplay = true
                    view.displayIfNeeded()
                }
                CATransaction.flush()
            }
            let surface = sidebar.container
            try #require(surface.bounds.width > 0 && surface.bounds.height > 0)
            let rep = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            scope.perform { surface.cacheDisplay(in: surface.bounds, to: rep) }
            let image = try #require(rep.cgImage)
            let png = out.appending(path: mode + ".png")
            let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))

            let rows = sidebar.container.sidebarView.debugRows().rows
            let painted = rows.filter { $0.inList && !$0.suppressed && ($0.viewAlpha ?? 0) > 0 }
                .sorted { $0.windowFrame.minY < $1.windowFrame.minY }.compactMap(\.title)
            let receipt: [String: Any] = [
                "kind": "native AppKit document-order regression; scripted transport and real Rust mirrors",
                "step_key": captureID,
                "appearance": mode, "theme": theme, "original_order": original,
                "actual_order": actual, "committed_order": committed, "expected_order": expected,
                "matches_expected": committed == expected, "painted_names": painted,
                "committed_names": expectedTitles, "painted_matches_committed": painted == expectedTitles,
                "moves": moves, "image": mode + ".png", "width": image.width, "height": image.height,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appending(path: mode + ".json"))
            // Nonthrowing: even failed painting evidence is packaged for diagnosis.
            // Expected-order failures belong to the original regression assertions.
            #expect(sidebar.model.selectableWorkspaces.map(\.id.rawValue) == committed)
            #expect(painted.count == committed.count, "the PNG must contain every committed workspace row")
            #expect(painted == expectedTitles, "painted native rows must match ACTUAL committed order")
        }

        // Package only this invocation's directory, even on the failing baseline.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = package
        tar.arguments = ["cf", archive.lastPathComponent, name]
        do {
            try await ControlDeadline.shared.run(method: "document placement capture archive", deadline: .now + .seconds(10)) { @MainActor in
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    tar.terminationHandler = { process in
                        if process.terminationStatus == 0 { continuation.resume() }
                        else { continuation.resume(throwing: CaptureFailure.archiveExit(process.terminationStatus)) }
                    }
                    do { try tar.run() }
                    catch { tar.terminationHandler = nil; continuation.resume(throwing: error) }
                }
            }
        } catch {
            if tar.isRunning { tar.terminate() }
            throw error
        }
        print("PLACEMENT_DOCUMENT_CAPTURE_ARTIFACT=\(archive.path)")
    }
}
