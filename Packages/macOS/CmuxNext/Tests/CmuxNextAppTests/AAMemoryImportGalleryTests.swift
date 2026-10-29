import AppKit
@testable import CmuxNextApp
@testable import CmuxNextChiefMemory
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import CmuxTheme
import Foundation
import Testing

/// The memory import flow as the person sees it, drawn offscreen with the real views: the Chief's front page with the
/// "Bring your memory from …" row, and the Import Memories dialog with the sources found on a Mac. PNGs under
/// `memory-import-gallery/` in the package, bundled to `memory-import-gallery.tar` for `cmux-ci run --artifact`.
/// Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized) struct AAMemoryImportGalleryTests {
    private static let sources = MemorySource.parse(Data("""
    {"sources":[
      {"source":"claude-code","kind":"claude-code","count":95,"bytes":187814733,"path":"/Users/me/.claude/projects"},
      {"source":"claude-memory","kind":"claude-memory","count":722,"bytes":1757797,"path":"/Users/me/.claude/projects"},
      {"source":"codex","kind":"codex","count":14,"bytes":40213,"path":"/Users/me/.codex/memories"},
      {"source":"zip:/Users/me/Downloads/data-2026-10-20.zip","kind":"chatgpt-export","count":1,"bytes":9000000,"path":"/Users/me/Downloads/data-2026-10-20.zip"}
    ]}
    """.utf8))

    private static func shot(_ build: (NSView, NSWindow) -> Void, width: CGFloat, height: CGFloat, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        build(root, window)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    private static func frontPage(_ root: NSView, _ window: NSWindow) {
        let panel = HomeFirstRunView(frame: root.bounds)
        panel.autoresizingMask = [.width, .height]
        root.addSubview(panel)
        panel.setMemoryOffer(MemorySource.offerTitle(sources, locale: Locale(identifier: "en_US")))
        panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: nil)
        panel.layoutSubtreeIfNeeded()
    }

    private static func dialog(_ root: NSView, _ window: NSWindow) {
        let fields = sources.enumerated().map { CmuxDialogField.check(id: String($0.offset), title: $0.element.title, on: true) }
        let spec = CmuxDialogSpec(
            title: ChiefMemoryImportStrings.title,
            lines: [ChiefMemoryImportStrings.lead, ChiefMemoryImportStrings.safety, ChiefMemoryImportStrings.restartNote],
            fields: fields,
            buttons: [.cancel(), CmuxDialogButton(id: "file", title: ChiefMemoryImportStrings.chooseFile),
                      CmuxDialogButton(id: "import", title: ChiefMemoryImportStrings.importButton, role: .default)])
        let view = CmuxDialogView(spec: spec)
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: root.centerXAnchor), view.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "memory-import-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
            for (name, build, size) in [("front-page", Self.frontPage, CGSize(width: 520, height: 560)),
                                        ("dialog", Self.dialog, CGSize(width: 640, height: 520))] as [(String, (NSView, NSWindow) -> Void, CGSize)] {
                let image = try Self.shot(build, width: size.width, height: size.height, theme: theme, dark: dark)
                let url = out.appending(path: "\(name)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "memory-import-gallery.tar", "memory-import-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
