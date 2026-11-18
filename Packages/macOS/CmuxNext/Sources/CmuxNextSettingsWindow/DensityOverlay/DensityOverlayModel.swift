import AppKit
import CmuxNextDesign
import Observation
import UniformTypeIdentifiers

/// The Density Overlay Playground's state: the reference capture, the live capture of cmux's browser chrome, how the
/// two are shown, and their pixel diff. The canvas reads it; the toolbar's controls write it.
@MainActor @Observable final class DensityOverlayModel {
    /// How the canvas shows the two images.
    enum Mode: String, CaseIterable, Identifiable {
        /// The reference over cmux at ``DensityOverlayModel/opacity``.
        case overlay
        /// The difference blend: black where they match.
        case difference
        /// One image at a time; a click on the canvas swaps them (onion-skin flip).
        case flip
        /// One above the other.
        case sideBySide
        var id: String { rawValue }
    }

    /// The image to match (a Helium or Chrome capture, 2x).
    private(set) var reference: CGImage?
    /// The reference's file name.
    private(set) var referenceName: String?
    /// The reference captures checked in next to the tool's sources (``loadBuiltInReferences()``).
    private(set) var builtInReferences: [URL] = []
    /// cmux's chrome as last captured.
    private(set) var live: CGImage?
    /// The latest diff of ``live`` against ``reference``.
    private(set) var diff: DensityOverlayDiff?
    /// The live capture failed: no browser pane with an omnibar in a front window.
    private(set) var noBrowserPane = false
    var mode: Mode = .overlay { didSet { flipShowsReference = false } }
    /// The reference's opacity over cmux in ``Mode/overlay``.
    var opacity: Double = 0.5
    /// The canvas's magnification (the loupe), drawn without smoothing.
    var zoom: Double = 2
    /// The reference's offset from cmux's pane edge and top, in pixels (right and down positive).
    var offset: CGPoint = .zero { didSet { recomputeDiff() } }
    /// The channel difference under which two pixels count as the same (anti-aliasing), 0...255.
    var threshold: Double = 24 { didSet { recomputeDiff() } }
    /// In ``Mode/flip``: whether the reference is the image showing now.
    private(set) var flipShowsReference = false
    /// Captures again whenever a tuned value or the density changes, so a slider in the Controls panel shows at once.
    var isLive = true

    /// Swaps the image ``Mode/flip`` shows.
    func flip() { flipShowsReference.toggle() }

    /// Lists the reference captures checked in at plans/cmux-next/helium-density/refs, read off the main thread; found
    /// only in a checkout's dev build (a fleet build asks with ``chooseReference()``).
    func loadBuiltInReferences() {
        // This file is Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/DensityOverlay/ in the checkout: seven up.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let refs = root.appending(path: "plans/cmux-next/helium-density/refs", directoryHint: .isDirectory)
        Task { [weak self] in
            let found = await BrowserChromeReferenceFiles().pngs(in: refs)
            self?.builtInReferences = found
        }
    }

    /// Loads the reference at `url` (read off the main thread).
    func loadReference(_ url: URL) {
        Task { [weak self] in
            guard let data = await BrowserChromeReferenceFiles().data(at: url),
                  let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let self else { return }
            reference = image
            referenceName = url.lastPathComponent
            capture()
        }
    }

    /// Asks for a reference image with an open panel.
    func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadReference(url)
    }

    /// Captures cmux's chrome now, as wide as the reference, and diffs it.
    func capture() {
        guard let source = DensityOverlayCapture() else {
            noBrowserPane = true
            live = nil
            diff = nil
            return
        }
        noBrowserPane = false
        let scale = source.window.backingScaleFactor
        live = source.image(maxWidth: reference.map { CGFloat($0.width) / max(scale, 1) })
        recomputeDiff()
    }

    /// Moves the reference by `dx`, `dy` pixels.
    func nudge(dx: CGFloat, dy: CGFloat) { offset = CGPoint(x: offset.x + dx, y: offset.y + dy) }

    private func recomputeDiff() {
        guard let live, let reference else { return diff = nil }
        diff = DensityOverlayDiff(live: live, reference: reference, offset: offset, threshold: Int(threshold))
    }

    /// The window shows: list the references and capture.
    func appear() {
        loadBuiltInReferences()
        capture()
    }

    /// A tuned value or the density changed (the view's `onChange`): capture again while ``isLive``.
    func chromeDidChange() {
        if isLive { capture() }
    }
}
